//! 局域网网络信息工具。

/// 探测本机首选的局域网 IPv4 地址（优先物理网卡，排除回环/隧道/虚拟接口）。失败返回 None。
///
/// Windows 下用 GetAdaptersAddresses 枚举接口。
#[cfg(target_os = "windows")]
pub fn primary_lan_ipv4() -> Option<String> {
    use windows::Win32::Foundation::{ERROR_BUFFER_OVERFLOW, NO_ERROR};
    use windows::Win32::NetworkManagement::IpHelper::{
        GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER,
        GAA_FLAG_SKIP_MULTICAST, IP_ADAPTER_ADDRESSES_LH,
    };
    use windows::Win32::Networking::WinSock::{AF_INET, SOCKADDR_IN};

    unsafe {
        let family = AF_INET.0 as u32;
        let flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;

        // 先查所需缓冲大小。
        let mut size: u32 = 15 * 1024;
        let mut buf: Vec<u8> = vec![0u8; size as usize];
        let mut ret = GetAdaptersAddresses(
            family,
            flags,
            None,
            Some(buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH),
            &mut size,
        );
        if ret == ERROR_BUFFER_OVERFLOW.0 {
            buf = vec![0u8; size as usize];
            ret = GetAdaptersAddresses(
                family,
                flags,
                None,
                Some(buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH),
                &mut size,
            );
        }
        if ret != NO_ERROR.0 {
            return None;
        }

        let mut candidates: Vec<(bool, String)> = Vec::new();
        let mut adapter = buf.as_ptr() as *const IP_ADAPTER_ADDRESSES_LH;
        while !adapter.is_null() {
            let a = &*adapter;

            // 仅取已连通（IfOperStatusUp == 1）的接口。
            let up = a.OperStatus.0 == 1;
            // 排除回环（IF_TYPE_SOFTWARE_LOOPBACK == 24）与隧道（IF_TYPE_TUNNEL == 131）。
            let if_type = a.IfType;
            let is_physical = if_type != 24 && if_type != 131;

            // 接口友好描述，用于排除虚拟网卡。
            let desc = wide_to_string(a.Description.0).to_lowercase();
            let is_virtual = desc.contains("virtual")
                || desc.contains("vmware")
                || desc.contains("hyper-v")
                || desc.contains("vethernet")
                || desc.contains("wsl")
                || desc.contains("tailscale")
                || desc.contains("wireguard")
                || desc.contains("tap-")
                || desc.contains("loopback");

            // 是否无线（IF_TYPE_IEEE80211 == 71）或以太网（== 6），用于优先级排序。
            let preferred = if_type == 71 || if_type == 6;

            if up && is_physical && !is_virtual {
                let mut ua = a.FirstUnicastAddress;
                while !ua.is_null() {
                    let u = &*ua;
                    let sa = u.Address.lpSockaddr;
                    if !sa.is_null() && (*sa).sa_family == AF_INET {
                        let sin = &*(sa as *const SOCKADDR_IN);
                        let octets = sin.sin_addr.S_un.S_addr.to_ne_bytes();
                        let ip = format!("{}.{}.{}.{}", octets[0], octets[1], octets[2], octets[3]);
                        if !ip.starts_with("169.254.") && ip != "127.0.0.1" {
                            candidates.push((preferred, ip));
                        }
                    }
                    ua = u.Next;
                }
            }

            adapter = a.Next;
        }

        // 优先无线/以太网物理网卡。
        if let Some((_, ip)) = candidates.iter().find(|(p, _)| *p) {
            return Some(ip.clone());
        }
        candidates.into_iter().next().map(|(_, ip)| ip)
    }
}

#[cfg(target_os = "windows")]
unsafe fn wide_to_string(ptr: *const u16) -> String {
    if ptr.is_null() {
        return String::new();
    }
    let mut len = 0usize;
    while *ptr.add(len) != 0 {
        len += 1;
    }
    let slice = std::slice::from_raw_parts(ptr, len);
    String::from_utf16_lossy(slice)
}

#[cfg(not(target_os = "windows"))]
pub fn primary_lan_ipv4() -> Option<String> {
    None
}
