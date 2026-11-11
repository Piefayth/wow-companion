//! The streaming speech model's folder (the streaming engine, crates/voice
//! stream.rs): the files it holds, and the bpe.vocab sherpa-onnx needs to turn
//! hotwords into the model's tokens, made from its tokens.txt. Shared by the
//! setup window, which downloads and unpacks the model, and the voice loop,
//! which loads it.

use std::{fs, io, path::Path};

/// What the setup window unpacks from the model's archive.
pub const FILES: [&str; 4] = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"];
/// Made by `write_bpe_vocab` once the files are unpacked.
pub const BPE_VOCAB: &str = "bpe.vocab";

/// Write `dir`'s bpe.vocab from its tokens.txt: each piece with its score. A
/// SentencePiece BPE model's piece scores are its merge order, negated, which
/// is the piece's id here (tokens.txt lists "piece id").
pub fn write_bpe_vocab(dir: &Path) -> io::Result<()> {
    let tokens = fs::read_to_string(dir.join("tokens.txt"))?;
    let mut vocab = String::new();
    for line in tokens.lines() {
        let Some((piece, id)) = line.rsplit_once(' ') else {
            return Err(io::Error::other(format!("tokens.txt: a line without an id: {line:?}")));
        };
        let id: i64 = id.trim().parse().map_err(|_| io::Error::other(format!("tokens.txt: a bad id: {line:?}")))?;
        vocab.push_str(&format!("{piece}\t{}\n", -id));
    }
    fs::write(dir.join(BPE_VOCAB), vocab)
}

/// The files `dir` lacks, by name; empty when the model is complete.
pub fn missing(dir: &Path) -> Vec<String> {
    FILES
        .iter()
        .chain(std::iter::once(&BPE_VOCAB))
        .filter(|file| !dir.join(file).is_file())
        .map(|file| file.to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bpe_vocab_scores_each_piece_by_its_id() {
        let dir = std::env::temp_dir().join(format!("wc-bpe-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("tokens.txt"), "<unk> 0\n\u{2581}t 1\n\u{2581}th 2\n").unwrap();
        write_bpe_vocab(&dir).unwrap();
        assert_eq!(fs::read_to_string(dir.join(BPE_VOCAB)).unwrap(), "<unk>\t0\n\u{2581}t\t-1\n\u{2581}th\t-2\n");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_missing_file_is_named() {
        let dir = std::env::temp_dir().join(format!("wc-missing-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        assert_eq!(missing(&dir).len(), 5);
        fs::write(dir.join("tokens.txt"), "").unwrap();
        assert!(!missing(&dir).contains(&"tokens.txt".to_string()));
        fs::remove_dir_all(&dir).unwrap();
    }
}
