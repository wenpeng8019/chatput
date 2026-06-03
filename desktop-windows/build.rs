use embed_manifest::manifest::{DpiAwareness, MaxVersionTested};
use embed_manifest::{embed_manifest, new_manifest};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy)]
struct Rgba {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
}

impl Rgba {
    const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }
}

fn main() {
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        // 启用 Common Controls v6（现代 Win10/11 控件主题）+ Per-Monitor v2 DPI 感知。
        embed_manifest(
            new_manifest("Chatput.Desktop")
                .dpi_awareness(DpiAwareness::PerMonitorV2)
                .max_version_tested(MaxVersionTested::Windows10Version2004),
        )
        .expect("无法嵌入应用 manifest");

        let out_dir = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR"));
        let ico_path = out_dir.join("chatput.ico");
        let rc_path = out_dir.join("chatput.rc");
        write_icon(&ico_path).expect("无法生成应用图标");
        fs::write(
            &rc_path,
            format!("1 ICON \"{}\"\n", ico_path.display().to_string().replace('\\', "\\\\")),
        )
        .expect("无法生成资源脚本");
        embed_resource::compile(&rc_path, embed_resource::NONE);
    }
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../assets/icon/src/chatput-desktop.svg");
}

fn write_icon(path: &Path) -> io::Result<()> {
    let sizes = [16_u32, 32, 48, 256];
    let images: Vec<Vec<u8>> = sizes.iter().map(|&s| render_icon_dib(s)).collect();

    let mut file = fs::File::create(path)?;
    file.write_all(&0u16.to_le_bytes())?; // reserved
    file.write_all(&1u16.to_le_bytes())?; // icon
    file.write_all(&(sizes.len() as u16).to_le_bytes())?;

    let mut offset = 6 + sizes.len() as u32 * 16;
    for (&size, image) in sizes.iter().zip(images.iter()) {
        file.write_all(&[if size >= 256 { 0 } else { size as u8 }])?;
        file.write_all(&[if size >= 256 { 0 } else { size as u8 }])?;
        file.write_all(&[0])?; // colors
        file.write_all(&[0])?; // reserved
        file.write_all(&1u16.to_le_bytes())?; // planes
        file.write_all(&32u16.to_le_bytes())?; // bit count
        file.write_all(&(image.len() as u32).to_le_bytes())?;
        file.write_all(&offset.to_le_bytes())?;
        offset += image.len() as u32;
    }

    for image in images {
        file.write_all(&image)?;
    }
    Ok(())
}

fn render_icon_dib(size: u32) -> Vec<u8> {
    let scale = 4_u32;
    let hi = size * scale;
    let mut high = vec![Rgba { r: 0, g: 0, b: 0, a: 0 }; (hi * hi) as usize];

    let map = |v: f32| v * hi as f32 / 1024.0;

    // 背景 squircle：边缘使用纯白，避免圆角抗锯齿像素在 Explorer 白底上形成灰边。
    fill_round_rect(
        &mut high,
        hi,
        RectF::new(map(0.0), map(0.0), map(1024.0), map(1024.0)),
        map(229.0),
        Rgba::rgb(255, 255, 255),
    );

    // 内部铺一层极浅灰蓝，外缘仍保留纯白，避免圆角在白色 Explorer 背景上出现脏边。
    fill_round_rect(
        &mut high,
        hi,
        RectF::new(map(26.0), map(26.0), map(998.0), map(998.0)),
        map(205.0),
        Rgba::rgb(244, 247, 251),
    );

    let blue = Rgba::rgb(10, 149, 255);
    let bg = Rgba::rgb(255, 255, 255);

    // 水平镜像后的桌面端构图：气泡在后，键盘在前。
    let mx = |v: f32| map(1024.0 - v);

    // 后层气泡。
    fill_round_rect(&mut high, hi, RectF::new(mx(575.0), map(417.0), mx(163.0), map(753.0)), map(100.0), blue);
    fill_polygon(
        &mut high,
        hi,
        &[(mx(373.0), map(753.0)), (mx(277.0), map(829.0)), (mx(277.0), map(753.0))],
        blue,
    );

    // 前层键盘护城河 + 蓝面板。
    fill_round_rect(&mut high, hi, RectF::new(mx(861.0) - map(40.0), map(195.0) - map(40.0), mx(381.0) + map(40.0), map(495.0) + map(40.0)), map(80.0), bg);
    fill_round_rect(&mut high, hi, RectF::new(mx(861.0), map(195.0), mx(381.0), map(495.0)), map(60.0), blue);

    // 白键。
    let white = Rgba::rgb(255, 255, 255);
    for row in [78.0_f32, 148.0] {
        for col in [74.0_f32, 142.0, 210.0, 278.0, 346.0, 414.0] {
            fill_circle(&mut high, hi, mx(381.0 + col), map(195.0 + row), map(20.0), white);
        }
    }
    fill_round_rect(
        &mut high,
        hi,
        RectF::new(mx(381.0 + 350.0), map(195.0 + 216.0), mx(381.0 + 130.0), map(195.0 + 252.0)),
        map(18.0),
        white,
    );

    let pixels = downsample(&high, hi, size, scale);

    // ICO 内嵌 BMP：BITMAPINFOHEADER + BGRA bottom-up + 1bpp AND mask。
    // 32 位图标由 alpha 通道负责透明；AND mask 保持全 0，避免 1-bit mask 在圆角边缘产生灰色锯齿。
    let mask_stride = (size.div_ceil(32) * 4) as usize;
    let mut dib = Vec::with_capacity(40 + (size * size * 4) as usize + mask_stride * size as usize);
    dib.extend_from_slice(&40u32.to_le_bytes());
    dib.extend_from_slice(&(size as i32).to_le_bytes());
    dib.extend_from_slice(&((size * 2) as i32).to_le_bytes());
    dib.extend_from_slice(&1u16.to_le_bytes());
    dib.extend_from_slice(&32u16.to_le_bytes());
    dib.extend_from_slice(&0u32.to_le_bytes());
    dib.extend_from_slice(&(size * size * 4).to_le_bytes());
    dib.extend_from_slice(&0i32.to_le_bytes());
    dib.extend_from_slice(&0i32.to_le_bytes());
    dib.extend_from_slice(&0u32.to_le_bytes());
    dib.extend_from_slice(&0u32.to_le_bytes());

    for y in (0..size).rev() {
        for x in 0..size {
            let p = pixels[(y * size + x) as usize];
            dib.extend_from_slice(&[p.b, p.g, p.r, p.a]);

        }
    }

    dib.extend(std::iter::repeat_n(0, mask_stride * size as usize));
    dib
}

fn downsample(src: &[Rgba], src_size: u32, dst_size: u32, scale: u32) -> Vec<Rgba> {
    let mut out = Vec::with_capacity((dst_size * dst_size) as usize);
    let denom = scale * scale;
    for y in 0..dst_size {
        for x in 0..dst_size {
            let mut r = 0u32;
            let mut g = 0u32;
            let mut b = 0u32;
            let mut a = 0u32;
            for yy in 0..scale {
                for xx in 0..scale {
                    let p = src[((y * scale + yy) * src_size + (x * scale + xx)) as usize];
                    let pa = p.a as u32;
                    r += p.r as u32 * pa;
                    g += p.g as u32 * pa;
                    b += p.b as u32 * pa;
                    a += pa;
                }
            }
            let alpha = a / denom;
            out.push(Rgba {
                // 透明样本不参与 RGB 平均，避免圆角边缘把透明黑混进去形成深灰边。
                r: r.checked_div(a).unwrap_or(0) as u8,
                g: g.checked_div(a).unwrap_or(0) as u8,
                b: b.checked_div(a).unwrap_or(0) as u8,
                a: alpha as u8,
            });
        }
    }
    out
}

#[derive(Clone, Copy)]
struct RectF {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
}

impl RectF {
    const fn new(x0: f32, y0: f32, x1: f32, y1: f32) -> Self {
        Self { x0, y0, x1, y1 }
    }
}

fn fill_round_rect(buf: &mut [Rgba], size: u32, rect: RectF, radius: f32, color: Rgba) {
    let RectF {
        mut x0,
        y0,
        mut x1,
        y1,
    } = rect;
    if x0 > x1 {
        std::mem::swap(&mut x0, &mut x1);
    }
    let r = radius.min((x1 - x0) / 2.0).min((y1 - y0) / 2.0);
    let min_x = x0.floor().max(0.0) as u32;
    let max_x = x1.ceil().min(size as f32) as u32;
    let min_y = y0.floor().max(0.0) as u32;
    let max_y = y1.ceil().min(size as f32) as u32;
    for y in min_y..max_y {
        for x in min_x..max_x {
            let px = x as f32 + 0.5;
            let py = y as f32 + 0.5;
            let cx = px.clamp(x0 + r, x1 - r);
            let cy = py.clamp(y0 + r, y1 - r);
            if (px - cx).powi(2) + (py - cy).powi(2) <= r.powi(2) {
                buf[(y * size + x) as usize] = color;
            }
        }
    }
}

fn fill_circle(buf: &mut [Rgba], size: u32, cx: f32, cy: f32, radius: f32, color: Rgba) {
    let r2 = radius * radius;
    let min_x = (cx - radius).floor().max(0.0) as u32;
    let max_x = (cx + radius).ceil().min(size as f32) as u32;
    let min_y = (cy - radius).floor().max(0.0) as u32;
    let max_y = (cy + radius).ceil().min(size as f32) as u32;
    for y in min_y..max_y {
        for x in min_x..max_x {
            let dx = x as f32 + 0.5 - cx;
            let dy = y as f32 + 0.5 - cy;
            if dx * dx + dy * dy <= r2 {
                buf[(y * size + x) as usize] = color;
            }
        }
    }
}

fn fill_polygon(buf: &mut [Rgba], size: u32, pts: &[(f32, f32)], color: Rgba) {
    let min_x = pts.iter().map(|p| p.0).fold(f32::INFINITY, f32::min).floor().max(0.0) as u32;
    let max_x = pts.iter().map(|p| p.0).fold(f32::NEG_INFINITY, f32::max).ceil().min(size as f32) as u32;
    let min_y = pts.iter().map(|p| p.1).fold(f32::INFINITY, f32::min).floor().max(0.0) as u32;
    let max_y = pts.iter().map(|p| p.1).fold(f32::NEG_INFINITY, f32::max).ceil().min(size as f32) as u32;
    for y in min_y..max_y {
        for x in min_x..max_x {
            if point_in_polygon(x as f32 + 0.5, y as f32 + 0.5, pts) {
                buf[(y * size + x) as usize] = color;
            }
        }
    }
}

fn point_in_polygon(x: f32, y: f32, pts: &[(f32, f32)]) -> bool {
    let mut inside = false;
    let mut j = pts.len() - 1;
    for i in 0..pts.len() {
        let (xi, yi) = pts[i];
        let (xj, yj) = pts[j];
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
            inside = !inside;
        }
        j = i;
    }
    inside
}
