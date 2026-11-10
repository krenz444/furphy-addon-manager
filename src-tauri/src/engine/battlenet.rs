use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BattlenetInstall {
    pub product: String,
    pub uid: String,
    pub install_path: String,
}

/// product.db is a few kilobytes; anything near this size is not the file we expect.
const MAX_DB_BYTES: usize = 8 * 1024 * 1024;

/// Battle.net's list of installed games. FURPHY_TEST_PRODUCT_DB points a test at its own file.
pub fn product_db_path() -> PathBuf {
    match std::env::var_os("FURPHY_TEST_PRODUCT_DB") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(std::env::var_os("PROGRAMDATA").unwrap_or_default())
            .join("Battle.net")
            .join("Agent")
            .join("product.db"),
    }
}

enum Wire<'a> {
    Varint,
    Len(&'a [u8]),
    Fixed,
}

fn read_varint(data: &[u8], pos: &mut usize) -> Result<u64, String> {
    let mut value: u64 = 0;
    let mut shift = 0u32;
    loop {
        let byte = *data.get(*pos).ok_or_else(|| "Battle.net's product list is cut off".to_string())?;
        *pos += 1;
        if shift >= 64 {
            return Err("Battle.net's product list has a number that is too long".to_string());
        }
        value |= ((byte & 0x7F) as u64) << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
        shift += 7;
    }
}

/// The fields of one protobuf message as (field number, value); values that are not text-like are only skipped over.
fn read_fields(data: &[u8]) -> Result<Vec<(u64, Wire<'_>)>, String> {
    let mut fields = Vec::new();
    let mut pos = 0usize;
    while pos < data.len() {
        let tag = read_varint(data, &mut pos)?;
        let field = tag >> 3;
        match tag & 7 {
            0 => {
                read_varint(data, &mut pos)?;
                fields.push((field, Wire::Varint));
            }
            1 => {
                pos = pos.checked_add(8).filter(|end| *end <= data.len()).ok_or_else(|| "Battle.net's product list is cut off".to_string())?;
                fields.push((field, Wire::Fixed));
            }
            2 => {
                let len = read_varint(data, &mut pos)? as usize;
                let end = pos.checked_add(len).filter(|end| *end <= data.len()).ok_or_else(|| "Battle.net's product list is cut off".to_string())?;
                fields.push((field, Wire::Len(&data[pos..end])));
                pos = end;
            }
            5 => {
                pos = pos.checked_add(4).filter(|end| *end <= data.len()).ok_or_else(|| "Battle.net's product list is cut off".to_string())?;
                fields.push((field, Wire::Fixed));
            }
            other => return Err(format!("Battle.net's product list has an unknown entry type ({})", other)),
        }
    }
    Ok(fields)
}

fn text_of(value: &Wire<'_>) -> Option<String> {
    match value {
        Wire::Len(bytes) => Some(String::from_utf8_lossy(bytes).into_owned()),
        _ => None,
    }
}

/// Every product Battle.net records: field 1 holds the products, in each one field 1 is the product code, field 2 the
/// uid and field 3 the settings message whose field 1 is the install path. Unknown fields (the state message, hashes)
/// are skipped.
pub fn parse_product_db(bytes: &[u8]) -> Result<Vec<BattlenetInstall>, String> {
    if bytes.len() > MAX_DB_BYTES {
        return Err("Battle.net's product list is larger than expected".to_string());
    }
    let mut installs = Vec::new();
    for (field, value) in read_fields(bytes)? {
        if field != 1 {
            continue;
        }
        let Wire::Len(message) = value else { continue };
        let mut product = String::new();
        let mut uid = String::new();
        let mut install_path = String::new();
        for (inner_field, inner) in read_fields(message)? {
            match inner_field {
                1 => product = text_of(&inner).unwrap_or_default(),
                2 => uid = text_of(&inner).unwrap_or_default(),
                3 => {
                    if let Wire::Len(settings) = inner {
                        for (settings_field, settings_value) in read_fields(settings)? {
                            if settings_field == 1 {
                                install_path = text_of(&settings_value).unwrap_or_default();
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        if !product.is_empty() {
            installs.push(BattlenetInstall { product, uid, install_path });
        }
    }
    Ok(installs)
}

/// The install folders of the World of Warcraft products Battle.net knows (product codes that start with `wow`),
/// each once, that exist on disk.
pub fn wow_roots_from_product_db() -> Vec<PathBuf> {
    let Ok(bytes) = std::fs::read(product_db_path()) else {
        return Vec::new();
    };
    let Ok(installs) = parse_product_db(&bytes) else {
        return Vec::new();
    };
    let mut roots: Vec<PathBuf> = Vec::new();
    for install in installs.iter().filter(|i| i.product.starts_with("wow") && !i.install_path.is_empty()) {
        let path = PathBuf::from(install.install_path.replace('/', "\\"));
        let already = roots.iter().any(|r| r.to_string_lossy().eq_ignore_ascii_case(&path.to_string_lossy()));
        if !already && path.is_dir() {
            roots.push(path);
        }
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;

    fn varint(mut v: u64) -> Vec<u8> {
        let mut out = Vec::new();
        loop {
            let byte = (v & 0x7F) as u8;
            v >>= 7;
            if v == 0 {
                out.push(byte);
                return out;
            }
            out.push(byte | 0x80);
        }
    }

    fn field_len(field: u64, payload: &[u8]) -> Vec<u8> {
        let mut out = varint((field << 3) | 2);
        out.extend(varint(payload.len() as u64));
        out.extend_from_slice(payload);
        out
    }

    fn field_varint(field: u64, value: u64) -> Vec<u8> {
        let mut out = varint(field << 3);
        out.extend(varint(value));
        out
    }

    fn product(code: &str, uid: &str, path: Option<&str>) -> Vec<u8> {
        let mut msg = field_len(1, code.as_bytes());
        msg.extend(field_len(2, uid.as_bytes()));
        if let Some(p) = path {
            msg.extend(field_len(3, &field_len(1, p.as_bytes())));
        }
        // A state message with long hex text and a varint, as the real file has: ignored.
        let mut state = field_len(1, b"0123456789abcdef0123456789abcdef");
        state.extend(field_varint(2, 300));
        msg.extend(field_len(4, &state));
        field_len(1, &msg)
    }

    fn db(parts: &[Vec<u8>]) -> Vec<u8> {
        parts.concat()
    }

    #[test]
    fn products_uids_and_install_paths_are_read() {
        let bytes = db(&[
            product("agent", "agent", None),
            product("wow", "wow", Some("C:/Program Files (x86)/World of Warcraft")),
            product("wowf", "wowf", Some("C:/Program Files (x86)/World of Warcraft")),
        ]);
        let installs = parse_product_db(&bytes).unwrap();
        assert_eq!(installs.len(), 3);
        assert_eq!(installs[0], BattlenetInstall { product: "agent".into(), uid: "agent".into(), install_path: String::new() });
        assert_eq!(installs[1].product, "wow");
        assert_eq!(installs[1].install_path, "C:/Program Files (x86)/World of Warcraft");
        assert_eq!(installs[2].product, "wowf");
    }

    #[test]
    fn unknown_fields_and_a_second_top_level_field_are_skipped() {
        let mut bytes = field_varint(9, 7);
        bytes.extend(product("wow", "wow", Some("D:/WoW")));
        bytes.extend(field_len(2, b"other"));
        let installs = parse_product_db(&bytes).unwrap();
        assert_eq!(installs.len(), 1);
        assert_eq!(installs[0].install_path, "D:/WoW");
    }

    #[test]
    fn an_empty_buffer_is_an_empty_list() {
        assert!(parse_product_db(&[]).unwrap().is_empty());
    }

    #[test]
    fn a_truncated_buffer_is_a_plain_error_not_a_panic() {
        let full = product("wow", "wow", Some("C:/WoW"));
        for cut in [1, 2, 5, full.len() / 2, full.len() - 1] {
            assert!(parse_product_db(&full[..cut]).is_err(), "cut at {}", cut);
        }
        // a length that points far past the end
        assert!(parse_product_db(&[0x0A, 0xFF, 0xFF, 0xFF, 0x7F]).is_err());
        // an unknown wire type
        assert!(parse_product_db(&[0x0B]).is_err());
    }

    #[test]
    fn a_file_over_the_size_limit_is_refused() {
        let big = vec![0u8; MAX_DB_BYTES + 1];
        assert!(parse_product_db(&big).is_err());
    }

    #[test]
    fn the_roots_of_wow_products_are_distinct_and_exist() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("World of Warcraft");
        std::fs::create_dir_all(&root).unwrap();
        let forward = root.to_string_lossy().replace('\\', "/");
        let bytes = db(&[
            product("agent", "agent", Some(&forward)),
            product("wow", "wow", Some(&forward)),
            product("wowf", "wowf", Some(&forward.to_ascii_uppercase())),
            product("wow_classic", "wow_classic", Some("Z:/does/not/exist")),
        ]);
        let db_path = temp.path().join("product.db");
        std::fs::write(&db_path, bytes).unwrap();

        let previous = std::env::var_os("FURPHY_TEST_PRODUCT_DB");
        std::env::set_var("FURPHY_TEST_PRODUCT_DB", &db_path);
        let roots = wow_roots_from_product_db();
        match previous {
            Some(v) => std::env::set_var("FURPHY_TEST_PRODUCT_DB", v),
            None => std::env::remove_var("FURPHY_TEST_PRODUCT_DB"),
        }
        assert_eq!(roots.len(), 1, "agent is not a game, the second path differs only by case, the third does not exist: {:?}", roots);
    }
}
