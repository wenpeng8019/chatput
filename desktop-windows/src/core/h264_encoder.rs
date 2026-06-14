//! Windows Media Foundation H.264 编码器。
//!
//! 通过 MFT (Media Foundation Transform) 将 BGRA 帧编码为 H.264 Annex B 比特流。
//! 纯系统 API，零外部依赖。

use std::mem::ManuallyDrop;
use std::sync::Mutex;
use windows::Win32::Media::MediaFoundation::{
    MFCreateMemoryBuffer, MFCreateSample, MFShutdown, MFStartup,
    IMFTransform, IMFSample, IMFMediaBuffer,
    MFT_OUTPUT_DATA_BUFFER, MFT_OUTPUT_STREAM_INFO,
    MFT_MESSAGE_NOTIFY_BEGIN_STREAMING,
    MF_MT_FRAME_SIZE, MF_MT_FRAME_RATE, MF_MT_AVG_BITRATE,
    MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize,
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::Media::MediaFoundation::CLSID_MSH264EncoderMFT;

static MF_INIT: Mutex<u32> = Mutex::new(0);

fn ensure_mf() -> Result<(), String> {
    let mut count = MF_INIT.lock().unwrap();
    if *count == 0 {
        let MF_VERSION: u32 = 0x00020070;
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok()
                .map_err(|e| format!("CoInitializeEx: {e:?}"))?;
            MFStartup(MF_VERSION, 0)
                .map_err(|e| format!("MFStartup: {e:?}"))?;
        }
    }
    *count += 1;
    Ok(())
}

fn release_mf() {
    let mut count = MF_INIT.lock().unwrap();
    if *count == 0 { return; }
    *count -= 1;
    if *count == 0 {
        unsafe { MFShutdown().ok(); }
        unsafe { CoUninitialize(); }
    }
}

/// BGRA → NV12 转换。
fn bgra_to_nv12(bgra: &[u8], width: usize, height: usize) -> Vec<u8> {
    let y_size = width * height;
    let uv_size = (width / 2) * (height / 2) * 2;
    let mut nv12 = vec![0u8; y_size + uv_size];
    let (y_part, uv_part) = nv12.split_at_mut(y_size);
    for row in 0..height {
        for col in 0..width {
            let i = (row * width + col) * 4;
            if i + 3 >= bgra.len() { continue; }
            let b = bgra[i] as f64;
            let g = bgra[i + 1] as f64;
            let r = bgra[i + 2] as f64;
            y_part[row * width + col] =
                (0.257 * r + 0.504 * g + 0.098 * b + 16.0).round().clamp(16.0, 235.0) as u8;
            if row % 2 == 0 && col % 2 == 0 {
                let uv = (row / 2) * width + (col & !1);
                uv_part[uv] =
                    (-0.148 * r - 0.291 * g + 0.439 * b + 128.0).round().clamp(16.0, 240.0) as u8;
                uv_part[uv + 1] =
                    (0.439 * r - 0.368 * g - 0.071 * b + 128.0).round().clamp(16.0, 240.0) as u8;
            }
        }
    }
    nv12
}

/// MFT H.264 编码器。
pub struct H264Encoder {
    transform: ManuallyDrop<IMFTransform>,
    width: u32,
    height: u32,
    output_info: MFT_OUTPUT_STREAM_INFO,
    frame_seq: u64,
    frame_duration_hns: i64,
}

impl H264Encoder {
    pub fn width(&self) -> u32 { self.width }
    pub fn height(&self) -> u32 { self.height }

    pub fn new(width: u32, height: u32, fps: u32) -> Result<Self, String> {
        ensure_mf()?;

        let transform: IMFTransform = unsafe {
            CoCreateInstance(&CLSID_MSH264EncoderMFT, None, CLSCTX_INPROC_SERVER)
        }.map_err(|e| format!("CoCreateInstance: {e:?}"))?;

        // 步骤 1：取 MFT 原生输出类型为模板，仅修改尺寸/帧率/码率。
        let output_type = unsafe {
            let base = transform.GetOutputAvailableType(0, 0)
                .map_err(|e| format!("GetOutputAvailableType: {e:?}"))?;
            base.SetUINT64(&MF_MT_FRAME_SIZE, ((width as u64) << 32) | (height as u64))
                .map_err(|e| format!("FRAME_SIZE(out): {e:?}"))?;
            base.SetUINT64(&MF_MT_FRAME_RATE, ((fps as u64) << 32) | 1u64)
                .map_err(|e| format!("FRAME_RATE(out): {e:?}"))?;
            base.SetUINT32(&MF_MT_AVG_BITRATE, 4_000_000)
                .map_err(|e| format!("AVG_BITRATE(out): {e:?}"))?;
            base.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)
                .map_err(|e| format!("INTERLACE(out): {e:?}"))?;
            base
        };

        unsafe {
            transform.SetOutputType(0, &output_type, 0)
                .map_err(|e| format!("SetOutputType: {e:?}"))?;
        }

        // 步骤 2：取 MFT 原生输入类型为模板，仅修改尺寸/帧率。
        let input_type = unsafe {
            let base = transform.GetInputAvailableType(0, 0)
                .map_err(|e| format!("GetInputAvailableType: {e:?}"))?;
            base.SetUINT64(&MF_MT_FRAME_SIZE, ((width as u64) << 32) | (height as u64))
                .map_err(|e| format!("FRAME_SIZE(in): {e:?}"))?;
            base.SetUINT64(&MF_MT_FRAME_RATE, ((fps as u64) << 32) | 1u64)
                .map_err(|e| format!("FRAME_RATE(in): {e:?}"))?;
            base
        };

        unsafe {
            transform.SetInputType(0, &input_type, 0)
                .map_err(|e| format!("SetInputType: {e:?}"))?;
        }

        let output_info = unsafe {
            transform.GetOutputStreamInfo(0)
                .map_err(|e| format!("GetOutputStreamInfo: {e:?}"))?
        };

        unsafe {
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
                .map_err(|e| format!("ProcessMessage: {e:?}"))?;
        }

        Ok(H264Encoder {
            transform: ManuallyDrop::new(transform),
            width, height, output_info,
            frame_seq: 0,
            frame_duration_hns: (10_000_000i64 / fps as i64),
        })
    }

    /// 编码一帧 BGRA → H.264 NAL unit(s)。
    pub fn encode(&mut self, bgra: &[u8]) -> Result<Vec<u8>, String> {
        let nv12 = bgra_to_nv12(bgra, self.width as usize, self.height as usize);
        let buf_size = nv12.len() as u32;

        // 输入 sample。
        let input_sample: IMFSample = unsafe {
            MFCreateSample().map_err(|e| format!("MFCreateSample(in): {e:?}"))?
        };
        let input_buffer: IMFMediaBuffer = unsafe {
            MFCreateMemoryBuffer(buf_size)
                .map_err(|e| format!("MFCreateMemoryBuffer(in): {e:?}"))?
        };
        unsafe {
            let mut dst: *mut u8 = std::ptr::null_mut();
            input_buffer.Lock(&mut dst, None, None)
                .map_err(|e| format!("Lock(in): {e:?}"))?;
            std::ptr::copy_nonoverlapping(nv12.as_ptr(), dst, buf_size as usize);
            input_buffer.SetCurrentLength(buf_size)
                .map_err(|e| format!("SetCurrentLength(in): {e:?}"))?;
            input_buffer.Unlock().map_err(|e| format!("Unlock(in): {e:?}"))?;
        }
        unsafe {
            input_sample.AddBuffer(&input_buffer)
                .map_err(|e| format!("AddBuffer(in): {e:?}"))?;
            let ts = (self.frame_seq as i64) * self.frame_duration_hns;
            input_sample.SetSampleTime(ts)
                .map_err(|e| format!("SetSampleTime: {e:?}"))?;
            input_sample.SetSampleDuration(self.frame_duration_hns)
                .map_err(|e| format!("SetSampleDuration: {e:?}"))?;
        }
        self.frame_seq += 1;

        unsafe {
            self.transform.ProcessInput(0, &input_sample, 0)
                .map_err(|e| format!("ProcessInput: {e:?}"))?;
        }

        // 尝试取编码输出（循环直到 MFT 返回 NEED_MORE_INPUT）。
        let mut result = Vec::new();
        loop {
            let out_buf_size = self.output_info.cbSize.max(65536);
            let output_buffer: IMFMediaBuffer = unsafe {
                MFCreateMemoryBuffer(out_buf_size)
                    .map_err(|e| format!("MFCreateMemoryBuffer(out): {e:?}"))?
            };
            let output_sample: IMFSample = unsafe {
                MFCreateSample().map_err(|e| format!("MFCreateSample(out): {e:?}"))?
            };
            unsafe {
                output_sample.AddBuffer(&output_buffer)
                    .map_err(|e| format!("AddBuffer(out): {e:?}"))?;
            }

            let mut out_data = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: ManuallyDrop::new(Some(output_sample)),
                dwStatus: 0,
                pEvents: ManuallyDrop::new(None),
            }];
            let mut status: u32 = 0;
            let hr = unsafe {
                self.transform.ProcessOutput(0, &mut out_data, &mut status)
            };
            match hr {
                Ok(()) => {}
                Err(e) => {
                    // MF_E_TRANSFORM_NEED_MORE_INPUT — 正常，等更多帧。
                    if e.code().0 as u32 == 0xC00D6D72 {
                        break;
                    }
                    return Err(format!("ProcessOutput: {e:?}"));
                }
            }

            if let Some(ref out_sample) = *out_data[0].pSample {
                unsafe {
                    let buf = out_sample.GetBufferByIndex(0)
                        .map_err(|e| format!("GetBufferByIndex: {e:?}"))?;
                    let mut ptr: *mut u8 = std::ptr::null_mut();
                    let mut len: u32 = 0;
                    buf.Lock(&mut ptr, Some(&mut len), None)
                        .map_err(|e| format!("Lock(out): {e:?}"))?;
                    if len > 0 && !ptr.is_null() {
                        result.extend_from_slice(
                            std::slice::from_raw_parts(ptr, len as usize)
                        );
                    }
                    buf.Unlock().map_err(|e| format!("Unlock(out): {e:?}"))?;
                }
            }
        }
        Ok(result)
    }
}

impl Drop for H264Encoder {
    fn drop(&mut self) {
        unsafe { ManuallyDrop::drop(&mut self.transform); }
        release_mf();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn color_bars_bgra(width: u32, height: u32, frame_idx: u32) -> Vec<u8> {
        let mut buf = vec![0u8; (width * height * 4) as usize];
        let stripe_h = (height / 7).max(1);
        for y in 0..height {
            let stripe = (y / stripe_h) as u8 % 7;
            for x in 0..width {
                let i = ((y * width + x) * 4) as usize;
                match stripe {
                    0 => { buf[i]=255; buf[i+1]=0;   buf[i+2]=0;   } // B
                    1 => { buf[i]=0;   buf[i+1]=255; buf[i+2]=0;   } // G
                    2 => { buf[i]=0;   buf[i+1]=0;   buf[i+2]=255; } // R
                    3 => { buf[i]=255; buf[i+1]=255; buf[i+2]=0;   } // Cyan
                    4 => { buf[i]=255; buf[i+1]=0;   buf[i+2]=255; } // Magenta
                    5 => { buf[i]=0;   buf[i+1]=255; buf[i+2]=255; } // Yellow
                    _ => { buf[i]=128; buf[i+1]=128; buf[i+2]=128; } // Gray
                }
                buf[i+3] = 255;
            }
        }
        let _ = frame_idx; // 后续动画用
        buf
    }

    #[test]
    fn test_h264_encoder() {
        let w: u32 = 640;
        let h: u32 = 480;
        let fps: u32 = 15;
        let frames: u32 = 30;

        println!("\n=== H.264 编码器独立测试 ===");
        println!("创建编码器 {}x{} @ {}fps", w, h, fps);
        let mut enc = H264Encoder::new(w, h, fps).expect("创建编码器失败");

        let out_path = std::env::current_dir()
            .unwrap()
            .join("test_output.h264");
        let mut out = std::fs::File::create(&out_path).expect("创建输出文件");

        println!("编码 {} 帧 → {}", frames, out_path.display());
        let mut total: u64 = 0;
        let mut empty_ok = true; // 前几帧空输出正常（编码器攒帧中）
        for i in 0..frames {
            let bgra = color_bars_bgra(w, h, i);
            match enc.encode(&bgra) {
                Ok(data) => {
                    if data.is_empty() {
                        if empty_ok {
                            println!("  帧 #{}: (空 — 编码器攒帧中)", i+1);
                        }
                    } else {
                        empty_ok = false;
                        out.write_all(&data).ok();
                        total += data.len() as u64;
                        if total < data.len() as u64 * 2 || (i + 1) % 10 == 0 {
                            println!("  帧 #{}: {}B (累计 {}B)", i+1, data.len(), total);
                        }
                    }
                }
                Err(e) => {
                    println!("  帧 #{}: 失败 {}", i+1, e);
                    break;
                }
            }
        }
        println!("完成！{}B → {}", total, out_path.display());
        assert!(total > 0, "编码器应产生产出（攒帧完成后）");
    }
}
