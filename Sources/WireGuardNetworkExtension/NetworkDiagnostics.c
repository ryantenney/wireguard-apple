/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Copyright © 2026 Ryan Tenney.
 */

#include "NetworkDiagnostics.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/ioctl.h>
#include <sys/sockio.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* The iOS SDK does not ship <net/route.h>, so the routing-socket message
 * layout is mirrored here. These structures contain no pointers and have the
 * same layout on every Darwin platform (see xnu bsd/net/route.h). On macOS,
 * where the real header is available, the layout is verified at compile time. */

struct wgd_rt_metrics {
    uint32_t rmx_locks;
    uint32_t rmx_mtu;
    uint32_t rmx_hopcount;
    int32_t rmx_expire;
    uint32_t rmx_recvpipe;
    uint32_t rmx_sendpipe;
    uint32_t rmx_ssthresh;
    uint32_t rmx_rtt;
    uint32_t rmx_rttvar;
    uint32_t rmx_pksent;
    uint32_t rmx_state;
    uint32_t rmx_filler[3];
};

struct wgd_rt_msghdr {
    uint16_t rtm_msglen;
    uint8_t rtm_version;
    uint8_t rtm_type;
    uint16_t rtm_index;
    int32_t rtm_flags;
    int32_t rtm_addrs;
    int32_t rtm_pid;
    int32_t rtm_seq;
    int32_t rtm_errno;
    int32_t rtm_use;
    uint32_t rtm_inits;
    struct wgd_rt_metrics rtm_rmx;
};

#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <net/route.h>
_Static_assert(sizeof(struct wgd_rt_msghdr) == sizeof(struct rt_msghdr), "rt_msghdr mirror is out of sync with the SDK");
_Static_assert(sizeof(struct wgd_rt_metrics) == sizeof(struct rt_metrics), "rt_metrics mirror is out of sync with the SDK");
#endif

#ifndef NET_RT_DUMP
#define NET_RT_DUMP 1
#endif

#define WGD_RTA_DST 0x1
#define WGD_RTA_GATEWAY 0x2
#define WGD_RTA_NETMASK 0x4
#define WGD_RTA_GENMASK 0x8
#define WGD_RTA_IFP 0x10
#define WGD_RTA_IFA 0x20
#define WGD_RTA_AUTHOR 0x40
#define WGD_RTA_BRD 0x80

#define WGD_RTF_UP 0x1
#define WGD_RTF_GATEWAY 0x2
#define WGD_RTF_HOST 0x4
#define WGD_RTF_REJECT 0x8
#define WGD_RTF_DYNAMIC 0x10
#define WGD_RTF_MODIFIED 0x20
#define WGD_RTF_CLONING 0x100
#define WGD_RTF_XRESOLVE 0x200
#define WGD_RTF_LLINFO 0x400
#define WGD_RTF_STATIC 0x800
#define WGD_RTF_BLACKHOLE 0x1000
#define WGD_RTF_PROTO2 0x4000
#define WGD_RTF_PROTO1 0x8000
#define WGD_RTF_PRCLONING 0x10000
#define WGD_RTF_WASCLONED 0x20000
#define WGD_RTF_PROTO3 0x40000
#define WGD_RTF_LOCAL 0x200000
#define WGD_RTF_BROADCAST 0x400000
#define WGD_RTF_MULTICAST 0x800000
#define WGD_RTF_IFSCOPE 0x1000000
#define WGD_RTF_IFREF 0x4000000
#define WGD_RTF_PROXY 0x8000000
#define WGD_RTF_ROUTER 0x10000000
#define WGD_RTF_GLOBAL 0x40000000

#define WGD_AF_LINK 18

/* Socket addresses in routing messages are padded to 32-bit boundaries. */
#define WGD_ROUNDUP(a) ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))

static char *wgd_empty_string(void)
{
    char *empty = malloc(1);
    if (empty)
        empty[0] = '\0';
    return empty;
}

/* Growable output buffer. */
struct wgd_buffer {
    char *data;
    size_t length;
    size_t capacity;
    int failed;
};

static void wgd_buffer_append(struct wgd_buffer *buf, const char *text)
{
    size_t textLength = strlen(text);
    if (buf->failed)
        return;
    if (buf->length + textLength + 1 > buf->capacity) {
        size_t newCapacity = buf->capacity ? buf->capacity * 2 : 4096;
        while (newCapacity < buf->length + textLength + 1)
            newCapacity *= 2;
        char *newData = realloc(buf->data, newCapacity);
        if (!newData) {
            buf->failed = 1;
            return;
        }
        buf->data = newData;
        buf->capacity = newCapacity;
    }
    memcpy(buf->data + buf->length, text, textLength);
    buf->length += textLength;
    buf->data[buf->length] = '\0';
}

/* Copies a possibly truncated sockaddr into a zero-filled storage so that
 * fields past sa_len read as zero (netmasks are routinely truncated). */
static void wgd_copy_sockaddr(const struct sockaddr *sa, struct sockaddr_storage *out)
{
    memset(out, 0, sizeof(*out));
    if (!sa)
        return;
    size_t len = sa->sa_len;
    if (len > sizeof(*out))
        len = sizeof(*out);
    memcpy(out, sa, len);
}

static int wgd_prefix_length(const uint8_t *bytes, size_t count)
{
    int bits = 0;
    for (size_t i = 0; i < count; ++i) {
        uint8_t b = bytes[i];
        if (b == 0xff) {
            bits += 8;
            continue;
        }
        while (b & 0x80) {
            ++bits;
            b = (uint8_t)(b << 1);
        }
        break;
    }
    return bits;
}

static void wgd_format_address(const struct sockaddr_storage *ss, uint8_t family, char *out, size_t outlen)
{
    out[0] = '\0';
    if (family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)ss;
        inet_ntop(AF_INET, &sin->sin_addr, out, (socklen_t)outlen);
    } else if (family == AF_INET6) {
        struct sockaddr_in6 sin6;
        memcpy(&sin6, ss, sizeof(sin6));
        /* The kernel embeds the scope id in bytes 2-3 of link-local addresses. */
        uint32_t scope = 0;
        if (IN6_IS_ADDR_LINKLOCAL(&sin6.sin6_addr) || IN6_IS_ADDR_MC_LINKLOCAL(&sin6.sin6_addr)) {
            scope = ((uint32_t)sin6.sin6_addr.s6_addr[2] << 8) | sin6.sin6_addr.s6_addr[3];
            sin6.sin6_addr.s6_addr[2] = 0;
            sin6.sin6_addr.s6_addr[3] = 0;
        }
        inet_ntop(AF_INET6, &sin6.sin6_addr, out, (socklen_t)outlen);
        if (scope != 0) {
            char ifname[IF_NAMESIZE];
            size_t used = strlen(out);
            if (if_indextoname(scope, ifname))
                snprintf(out + used, outlen - used, "%%%s", ifname);
            else
                snprintf(out + used, outlen - used, "%%%u", scope);
        }
    } else if (family == WGD_AF_LINK) {
        /* struct sockaddr_dl: sdl_len, sdl_family, then uint16_t sdl_index. */
        uint16_t index = 0;
        memcpy(&index, ((const uint8_t *)ss) + 2, sizeof(index));
        snprintf(out, outlen, "link#%u", index);
    } else {
        snprintf(out, outlen, "af%u", family);
    }
}

static void wgd_format_flags(int32_t flags, char *out, size_t outlen)
{
    static const struct { int32_t bit; char letter; } table[] = {
        { WGD_RTF_UP, 'U' },
        { WGD_RTF_GATEWAY, 'G' },
        { WGD_RTF_HOST, 'H' },
        { WGD_RTF_REJECT, 'R' },
        { WGD_RTF_DYNAMIC, 'D' },
        { WGD_RTF_MODIFIED, 'M' },
        { WGD_RTF_MULTICAST, 'm' },
        { WGD_RTF_CLONING, 'C' },
        { WGD_RTF_XRESOLVE, 'X' },
        { WGD_RTF_LLINFO, 'L' },
        { WGD_RTF_STATIC, 'S' },
        { WGD_RTF_PROTO1, '1' },
        { WGD_RTF_PROTO2, '2' },
        { WGD_RTF_WASCLONED, 'W' },
        { WGD_RTF_PRCLONING, 'c' },
        { WGD_RTF_PROTO3, '3' },
        { WGD_RTF_BLACKHOLE, 'B' },
        { WGD_RTF_BROADCAST, 'b' },
        { WGD_RTF_IFSCOPE, 'I' },
        { WGD_RTF_IFREF, 'i' },
        { WGD_RTF_PROXY, 'Y' },
        { WGD_RTF_ROUTER, 'r' },
        { WGD_RTF_GLOBAL, 'g' },
    };
    size_t used = 0;
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]) && used + 1 < outlen; ++i) {
        if (flags & table[i].bit)
            out[used++] = table[i].letter;
    }
    out[used] = '\0';
}

static int wgd_is_all_zero(const uint8_t *bytes, size_t count)
{
    for (size_t i = 0; i < count; ++i) {
        if (bytes[i] != 0)
            return 0;
    }
    return 1;
}

static void wgd_append_route(struct wgd_buffer *buf, const struct wgd_rt_msghdr *rtm, const struct sockaddr *addrs[8])
{
    struct sockaddr_storage dst;
    struct sockaddr_storage gateway;
    struct sockaddr_storage netmask;
    char dstText[128];
    char gatewayText[128];
    char flagsText[32];
    char ifname[IF_NAMESIZE];
    char line[512];
    uint8_t family;
    const char *familyName;
    int prefix = -1;

    if (!addrs[0])
        return;

    wgd_copy_sockaddr(addrs[0], &dst);
    wgd_copy_sockaddr(addrs[1], &gateway);
    wgd_copy_sockaddr(addrs[2], &netmask);

    family = ((const struct sockaddr *)&dst)->sa_family;
    if (family == AF_INET) {
        familyName = "inet";
        if (!(rtm->rtm_flags & WGD_RTF_HOST)) {
            const struct sockaddr_in *mask = (const struct sockaddr_in *)&netmask;
            prefix = addrs[2] ? wgd_prefix_length((const uint8_t *)&mask->sin_addr, 4) : 32;
        }
    } else if (family == AF_INET6) {
        familyName = "inet6";
        if (!(rtm->rtm_flags & WGD_RTF_HOST)) {
            const struct sockaddr_in6 *mask = (const struct sockaddr_in6 *)&netmask;
            prefix = addrs[2] ? wgd_prefix_length(mask->sin6_addr.s6_addr, 16) : 128;
        }
    } else {
        return;
    }

    wgd_format_address(&dst, family, dstText, sizeof(dstText));

    if (prefix == 0) {
        const uint8_t *dstBytes = family == AF_INET
            ? (const uint8_t *)&((const struct sockaddr_in *)&dst)->sin_addr
            : ((const struct sockaddr_in6 *)&dst)->sin6_addr.s6_addr;
        if (wgd_is_all_zero(dstBytes, family == AF_INET ? 4 : 16))
            snprintf(dstText, sizeof(dstText), "default");
        else
            snprintf(dstText + strlen(dstText), sizeof(dstText) - strlen(dstText), "/0");
    } else if (prefix > 0) {
        size_t used = strlen(dstText);
        snprintf(dstText + used, sizeof(dstText) - used, "/%d", prefix);
    }

    gatewayText[0] = '\0';
    if (addrs[1]) {
        uint8_t gatewayFamily = ((const struct sockaddr *)&gateway)->sa_family;
        wgd_format_address(&gateway, gatewayFamily, gatewayText, sizeof(gatewayText));
    }

    wgd_format_flags(rtm->rtm_flags, flagsText, sizeof(flagsText));

    if (rtm->rtm_index == 0 || !if_indextoname(rtm->rtm_index, ifname))
        ifname[0] = '\0';

    snprintf(line, sizeof(line), "%s\t%s\t%s\t%s\t%s\t%u\t%d\n",
             familyName, dstText, gatewayText, flagsText, ifname,
             rtm->rtm_rmx.rmx_mtu, rtm->rtm_rmx.rmx_expire);
    wgd_buffer_append(buf, line);
}

char *wgd_dump_routing_table(void)
{
    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP, 0 };
    size_t needed = 0;
    char *table = NULL;
    int tableIsEmpty = 0;
    struct wgd_buffer out = { NULL, 0, 0, 0 };

    /* The table can grow between the size query and the fetch; retry a few times. */
    for (int attempt = 0; attempt < 5; ++attempt) {
        if (sysctl(mib, 6, NULL, &needed, NULL, 0) < 0)
            return NULL;
        if (needed == 0) {
            tableIsEmpty = 1;
            break;
        }
        needed += needed / 8 + 1024;
        table = malloc(needed);
        if (!table)
            return NULL;
        if (sysctl(mib, 6, table, &needed, NULL, 0) == 0)
            break;
        free(table);
        table = NULL;
        if (errno != ENOMEM)
            return NULL;
    }
    if (!table)
        return tableIsEmpty ? wgd_empty_string() : NULL;

    const char *cursor = table;
    const char *end = table + needed;
    while (cursor + sizeof(struct wgd_rt_msghdr) <= end) {
        const struct wgd_rt_msghdr *rtm = (const struct wgd_rt_msghdr *)cursor;
        size_t messageLength = rtm->rtm_msglen;
        if (messageLength < sizeof(struct wgd_rt_msghdr) || cursor + messageLength > end)
            break;

        const struct sockaddr *addrs[8] = { NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL };
        const char *saCursor = cursor + sizeof(struct wgd_rt_msghdr);
        const char *messageEnd = cursor + messageLength;
        for (int i = 0; i < 8; ++i) {
            if (!(rtm->rtm_addrs & (1 << i)))
                continue;
            if (saCursor + 2 > messageEnd)
                break;
            const struct sockaddr *sa = (const struct sockaddr *)saCursor;
            addrs[i] = sa;
            saCursor += WGD_ROUNDUP(sa->sa_len);
            if (saCursor > messageEnd)
                break;
        }

        /* Skip link-layer neighbour entries and cloned host routes derived from them. */
        if (!(rtm->rtm_flags & (WGD_RTF_LLINFO | WGD_RTF_WASCLONED)))
            wgd_append_route(&out, rtm, addrs);

        cursor += messageLength;
    }

    free(table);

    if (out.failed) {
        free(out.data);
        return NULL;
    }
    if (!out.data)
        return wgd_empty_string();
    return out.data;
}

int wgd_interface_mtu(const char *ifname)
{
    if (!ifname || !*ifname)
        return -1;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name));
    int ret = ioctl(fd, SIOCGIFMTU, &ifr);
    close(fd);
    if (ret != 0)
        return -1;
    return ifr.ifr_mtu;
}
