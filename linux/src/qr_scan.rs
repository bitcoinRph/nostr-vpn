use std::path::Path;

pub fn decode_from_path(path: &Path) -> Result<String, String> {
    let image = image::open(path).map_err(|error| format!("Could not read image: {error}"))?;
    let luma = image.to_luma8();
    let mut prepared = rqrr::PreparedImage::prepare(luma);

    for grid in prepared.detect_grids() {
        if let Ok((_meta, content)) = grid.decode() {
            let content = content.trim().to_string();
            if !content.is_empty() {
                return Ok(content);
            }
        }
    }

    Err("No QR code found".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{GrayImage, Luma};
    use qrcode::QrCode;

    #[test]
    fn decodes_qr_png() {
        let text = "nvpn://invite/test";
        let code = QrCode::new(text.as_bytes()).expect("build qr");
        let modules = code.width();
        let quiet = 4usize;
        let scale = 8usize;
        let size = (modules + quiet * 2) * scale;
        let colors = code.to_colors();
        let image = GrayImage::from_fn(size as u32, size as u32, |x, y| {
            let module_x = x as usize / scale;
            let module_y = y as usize / scale;
            if module_x < quiet
                || module_y < quiet
                || module_x >= modules + quiet
                || module_y >= modules + quiet
            {
                return Luma([255]);
            }
            let index = (module_y - quiet) * modules + (module_x - quiet);
            if matches!(colors[index], qrcode::Color::Dark) {
                Luma([0])
            } else {
                Luma([255])
            }
        });
        let path = std::env::temp_dir().join(format!("nostr-vpn-qr-{}.png", std::process::id()));
        image.save(&path).expect("write qr png");

        let decoded = decode_from_path(&path).expect("decode qr png");
        let _ = std::fs::remove_file(&path);

        assert_eq!(decoded, text);
    }
}
