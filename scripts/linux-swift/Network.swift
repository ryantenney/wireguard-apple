// SPDX-License-Identifier: MIT
// Copyright © 2026 Ryan Tenney.
//
// Minimal stand-in for Apple's Network framework, just enough to type-check the
// platform-independent parts of WireGuardKit on Linux (see typecheck.sh). It is
// never linked into the apps; only the shapes the model layer touches are here.
import Foundation

public protocol IPAddress {
    var rawValue: Data { get }
    init?(_ rawValue: Data, _ interface: NWInterface?)
    init?(_ string: String)
}

public struct IPv4Address: IPAddress, Hashable, CustomDebugStringConvertible {
    public let rawValue: Data
    public init?(_ rawValue: Data, _ interface: NWInterface? = nil) { guard rawValue.count == 4 else { return nil }; self.rawValue = rawValue }
    public init?(_ string: String) {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        self.rawValue = withUnsafeBytes(of: &addr) { Data($0) }
    }
    public var debugDescription: String { rawValue.map { String($0) }.joined(separator: ".") }
}

public struct IPv6Address: IPAddress, Hashable, CustomDebugStringConvertible {
    public let rawValue: Data
    public init?(_ rawValue: Data, _ interface: NWInterface? = nil) { guard rawValue.count == 16 else { return nil }; self.rawValue = rawValue }
    public init?(_ string: String) {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, string, &addr) == 1 else { return nil }
        self.rawValue = withUnsafeBytes(of: &addr) { Data($0) }
    }
    public var debugDescription: String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var raw = rawValue
        return raw.withUnsafeMutableBytes { p in String(cString: inet_ntop(AF_INET6, p.baseAddress, &buf, socklen_t(buf.count))) }
    }
}

public struct NWInterface: Hashable {
    public enum InterfaceType: Hashable { case wifi, cellular, wiredEthernet, loopback, other }
    public let name: String
    public let type: InterfaceType
    public init(name: String, type: InterfaceType) { self.name = name; self.type = type }
}

public enum NWEndpoint: Hashable, CustomDebugStringConvertible {
    public enum Host: Hashable, CustomDebugStringConvertible {
        case name(String, NWInterface?)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
        public init(_ string: String) {
            if let v4 = IPv4Address(string) { self = .ipv4(v4) } else if let v6 = IPv6Address(string) { self = .ipv6(v6) } else { self = .name(string, nil) }
        }
        public var debugDescription: String {
            switch self { case .name(let n, _): return n; case .ipv4(let a): return a.debugDescription; case .ipv6(let a): return a.debugDescription }
        }
    }
    public struct Port: Hashable, RawRepresentable, CustomDebugStringConvertible {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public init(integerLiteral value: UInt16) { self.rawValue = value }
        public init?(_ string: String) { guard let v = UInt16(string) else { return nil }; self.rawValue = v }
        public var debugDescription: String { String(rawValue) }
    }
    case hostPort(host: Host, port: Port)
    case service(name: String, type: String, domain: String, interface: NWInterface?)
    case unix(path: String)
    case url(URL)
    public var debugDescription: String { "\(self)" }
}
