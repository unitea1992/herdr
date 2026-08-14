use std::io::{self, Write};

const BELL_CHUNK: [u8; 64] = [b'\x07'; 64];

pub(crate) fn write_terminal_bells<W: Write>(writer: &mut W, count: u16) -> io::Result<()> {
    let full_chunks = usize::from(count) / BELL_CHUNK.len();
    let remainder = usize::from(count) % BELL_CHUNK.len();
    for _ in 0..full_chunks {
        writer.write_all(&BELL_CHUNK)?;
    }
    writer.write_all(&BELL_CHUNK[..remainder])?;
    writer.flush()
}

pub(crate) fn write_window_title<W: Write>(writer: &mut W, title: Option<&str>) -> io::Result<()> {
    let title = title.unwrap_or("herdr");
    let safe_title = title
        .chars()
        .filter(|ch| !matches!(*ch, '\u{1b}' | '\u{7}' | '\u{9c}'))
        .collect::<String>();
    write!(writer, "\x1b]0;{safe_title}\x07")?;
    writer.flush()
}

/// Reports the focused pane's working directory to the host terminal with
/// iTerm2/Tabby's `OSC 1337;CurrentDir=...` convention. The path is sent as
/// raw UTF-8: Tabby consumes `CurrentDir` as-is without percent-decoding, so
/// encoding would corrupt paths containing `%`. Only the OSC-breaking control
/// characters are stripped.
pub(crate) fn write_current_dir<W: Write>(writer: &mut W, cwd: &std::path::Path) -> io::Result<()> {
    let safe_cwd = cwd
        .to_string_lossy()
        .chars()
        .filter(|ch| !matches!(*ch, '\u{1b}' | '\u{7}' | '\u{9c}'))
        .collect::<String>();
    write!(writer, "\x1b]1337;CurrentDir={safe_cwd}\x07")?;
    writer.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_exact_terminal_bell_count() {
        let mut output = Vec::new();

        write_terminal_bells(&mut output, 130).unwrap();

        assert_eq!(output, vec![b'\x07'; 130]);
    }

    #[test]
    fn window_title_strips_terminators_and_defaults_to_herdr() {
        let mut output = Vec::new();
        write_window_title(&mut output, Some("herdr\x1b api\u{7}\u{9c}")).unwrap();
        assert_eq!(output, b"\x1b]0;herdr api\x07");

        output.clear();
        write_window_title(&mut output, None).unwrap();
        assert_eq!(output, b"\x1b]0;herdr\x07");
    }

    #[test]
    fn current_dir_emits_raw_osc_1337_path() {
        let mut output = Vec::new();
        write_current_dir(&mut output, std::path::Path::new("/home/user/my repo/a+b")).unwrap();
        assert_eq!(output, b"\x1b]1337;CurrentDir=/home/user/my repo/a+b\x07");

        output.clear();
        write_current_dir(
            &mut output,
            std::path::Path::new("/tmp/x\x1b]0;evil\x07\u{9c}"),
        )
        .unwrap();
        assert_eq!(output, b"\x1b]1337;CurrentDir=/tmp/x]0;evil\x07");
    }
}
