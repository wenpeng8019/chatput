//! 局域网网络信息工具。

/// 探测本机首选的局域网 IPv4 地址（优先有默认网关的可用私网地址）。失败返回 None。
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

        let mut candidates: Vec<(i32, String)> = Vec::new();
        let mut adapter = buf.as_ptr() as *const IP_ADAPTER_ADDRESSES_LH;
        while !adapter.is_null() {
            let a = &*adapter;

            // 仅取已连通（IfOperStatusUp == 1）的接口。
            let up = a.OperStatus.0 == 1;
            // 排除回环（IF_TYPE_SOFTWARE_LOOPBACK == 24）与隧道（IF_TYPE_TUNNEL == 131）。
            let if_type = a.IfType;
            let is_physical = if_type != 24 && if_type != 131;

            // 接口友好描述/名称，用于排除明显的代理/隧道接口；不要仅因 vEthernet/WSL 字样排除，
            // 部分 Windows 网络桥接会把真实可达的 Wi-Fi 地址挂在 vEthernet 上。
            let desc = wide_to_string(a.Description.0).to_lowercase();
            let name = wide_to_string(a.FriendlyName.0).to_lowercase();
            let adapter_text = format!("{} {}", desc, name);
            let is_default_switch = adapter_text.contains("default switch");
            let is_disallowed_tunnel = adapter_text.contains("vmware")
                || adapter_text.contains("tailscale")
                || adapter_text.contains("wireguard")
                || adapter_text.contains("clash")
                || adapter_text.contains("flclash")
                || adapter_text.contains("proxy")
                || adapter_text.contains("tap-")
                || adapter_text.contains("loopback")
                || adapter_text.contains("tun");
            let has_gateway = !a.FirstGatewayAddress.is_null();

            // 是否无线（IF_TYPE_IEEE80211 == 71）或以太网（== 6），用于优先级排序。
            let preferred = if_type == 71
                || if_type == 6
                || adapter_text.contains("wifi")
                || adapter_text.contains("wi-fi")
                || adapter_text.contains("ethernet")
                || adapter_text.contains("以太网")
                || adapter_text.contains("无线");
            let is_virtual_like = adapter_text.contains("virtual")
                || adapter_text.contains("hyper-v")
                || adapter_text.contains("vethernet")
                || adapter_text.contains("wsl");

            if up && is_physical && !is_default_switch && !is_disallowed_tunnel {
                let mut ua = a.FirstUnicastAddress;
                while !ua.is_null() {
                    let u = &*ua;
                    let sa = u.Address.lpSockaddr;
                    if !sa.is_null() && (*sa).sa_family == AF_INET {
                        let sin = &*(sa as *const SOCKADDR_IN);
                        let octets = sin.sin_addr.S_un.S_addr.to_ne_bytes();
                        let ip = format!("{}.{}.{}.{}", octets[0], octets[1], octets[2], octets[3]);
                        if is_usable_lan_ipv4(&ip) {
                            let mut score = 0;
                            if has_gateway {
                                score += 100;
                            }
                            if preferred {
                                score += 20;
                            }
                            if !is_virtual_like {
                                score += 10;
                            }
                            candidates.push((score, ip));
                        }
                    }
                    ua = u.Next;
                }
            }

            adapter = a.Next;
        }

        candidates.sort_by_key(|candidate| std::cmp::Reverse(candidate.0));
        candidates.into_iter().next().map(|(_, ip)| ip)
    }
}

#[cfg(target_os = "windows")]
fn is_usable_lan_ipv4(ip: &str) -> bool {
    let parts: Vec<u8> = ip.split('.').filter_map(|p| p.parse::<u8>().ok()).collect();
    if parts.len() != 4 {
        return false;
    }
    match (parts[0], parts[1]) {
        (10, _) => true,
        (172, 16..=31) => true,
        (192, 168) => true,
        // 明确排除：回环、链路本地、CGNAT、benchmark/proxy 常见段（Clash 常用 198.18/15）。
        (127, _) | (169, 254) | (100, 64..=127) | (198, 18..=19) => false,
        _ => false,
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
