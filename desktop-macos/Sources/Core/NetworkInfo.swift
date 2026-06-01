import Foundation

/// 局域网网络信息工具。
enum NetworkInfo {
    /// 探测本机首选的局域网 IPv4 地址（优先 en0/en1，排除回环与隧道）。
    /// 失败返回 nil。
    static func primaryLANIPv4() -> String? {
        var candidates: [(iface: String, ip: String)] = []

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            // 排除隧道/虚拟接口。
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("bridge") {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: host)
            if ip.isEmpty || ip.hasPrefix("169.254.") { continue }
            candidates.append((name, ip))
        }

        // 优先 en0 / en1（典型 Wi-Fi / 以太网），否则取第一个。
        for preferred in ["en0", "en1"] {
            if let match = candidates.first(where: { $0.iface == preferred }) {
                return match.ip
            }
        }
        return candidates.first?.ip
    }
}
