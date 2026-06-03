//! 用 qrcode crate 生成二维码 RGBA 像素，供 egui 显示。

use qrcode::QrCode;

/// 生成的二维码图像（RGBA8，正方形）。
pub struct QrImage {
    pub size: usize,
    pub rgba: Vec<u8>,
}

/// 由内容生成二维码。`module_px` 为每个码点像素数，`quiet` 为安静区码点数。
pub fn generate(content: &str, module_px: usize, quiet: usize) -> Option<QrImage> {
    if content.is_empty() {
        return None;
    }
    let code = QrCode::new(content.as_bytes()).ok()?;
    let width = code.width();
    let total_modules = width + quiet * 2;
    let size = total_modules * module_px;

    let mut rgba = vec![255u8; size * size * 4];

    for y in 0..width {
        for x in 0..width {
            let dark = code[(x, y)] == qrcode::Color::Dark;
            if !dark {
                continue;
            }
            // 映射到含安静区的像素块。
            let px0 = (x + quiet) * module_px;
            let py0 = (y + quiet) * module_px;
            for dy in 0..module_px {
                for dx in 0..module_px {
                    let px = px0 + dx;
                    let py = py0 + dy;
                    let idx = (py * size + px) * 4;
                    rgba[idx] = 0;
                    rgba[idx + 1] = 0;
                    rgba[idx + 2] = 0;
                    rgba[idx + 3] = 255;
                }
            }
        }
    }

    Some(QrImage { size, rgba })
}
