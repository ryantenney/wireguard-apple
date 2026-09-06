/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Copyright © 2026 Ryan Tenney.
 *
 * Low-level network diagnostics used by the connection details view.
 */

#ifndef NETWORK_DIAGNOSTICS_H
#define NETWORK_DIAGNOSTICS_H

/* Dumps the kernel routing table via the PF_ROUTE sysctl.
 *
 * Returns a malloc'd, newline-delimited string; the caller must free() it.
 * Each line has seven tab-separated fields:
 *
 *   family  destination  gateway  flags  interface  mtu  expire
 *
 * `family` is "inet" or "inet6". `destination` is "default", a host address,
 * or "prefix/len". `gateway` is an address, "link#N" for directly attached
 * routes, or "" when absent. `flags` uses netstat's letter codes. `mtu` and
 * `expire` are 0 when unset. Link-layer (ARP/NDP) entries are omitted.
 *
 * Returns NULL if the table could not be read. */
char *wgd_dump_routing_table(void);

/* Returns the MTU of the named interface, or -1 on failure. */
int wgd_interface_mtu(const char *ifname);

#endif
