//! Which bits of a HID pad's input report are buttons, from the pad's own report
//! descriptor (HID 1.11, 6.2.2): every Input item on the Button usage page, by
//! the bit it occupies in the report as hidapi reads it (the report id byte
//! first when the pad numbers its reports; Windows' hidapi strips a zero id).

use crate::Press;

/// The buttons in the first report that carries any, and that report's id
/// (None when the pad does not number its reports).
pub(crate) fn buttons(descriptor: &[u8]) -> (Option<u8>, Vec<Press>) {
    const BUTTON_PAGE: u32 = 0x09;
    let mut page = 0u32;
    let mut size = 0usize;
    let mut count = 0usize;
    let mut id = 0u8;
    let mut pushed: Vec<(u32, usize, usize, u8)> = Vec::new();
    // each report's next free bit, by id
    let mut next: Vec<(u8, usize)> = Vec::new();
    let mut found: Option<(u8, Vec<Press>)> = None;
    let mut at = 0;
    while at < descriptor.len() {
        let prefix = descriptor[at];
        // a long item: its size is the next byte, and nothing here uses one
        if prefix == 0xfe {
            at += 3 + descriptor.get(at + 1).copied().unwrap_or(0) as usize;
            continue;
        }
        let length = [0, 1, 2, 4][(prefix & 0x03) as usize];
        let Some(bytes) = descriptor.get(at + 1..at + 1 + length) else { break };
        let data = bytes.iter().rev().fold(0u32, |value, byte| (value << 8) | u32::from(*byte));
        at += 1 + length;
        match (prefix >> 2) & 0x03 {
            // global items
            1 => match prefix >> 4 {
                0x0 => page = data,
                0x7 => size = data as usize,
                0x8 => id = data as u8,
                0x9 => count = data as usize,
                0xa => pushed.push((page, size, count, id)),
                0xb => {
                    if let Some(state) = pushed.pop() {
                        (page, size, count, id) = state;
                    }
                }
                _ => {}
            },
            // main items: an Input takes its bits from its report
            0 if prefix >> 4 == 0x8 => {
                let start = match next.iter().find(|(each, _)| *each == id) {
                    Some((_, bit)) => *bit,
                    None => {
                        let first = if id == 0 { 0 } else { 8 };
                        next.push((id, first));
                        first
                    }
                };
                let bits = size * count;
                if let Some((_, bit)) = next.iter_mut().find(|(each, _)| *each == id) {
                    *bit = start + bits;
                }
                // a variable (bit 1), not constant (bit 0), one bit per button
                let variable = data & 0x02 != 0 && data & 0x01 == 0;
                if page == BUTTON_PAGE && variable && size == 1 {
                    let presses = (start..start + bits).map(|bit| Press { byte: bit / 8, mask: 1 << (bit % 8) });
                    match &mut found {
                        None => found = Some((id, presses.collect())),
                        Some((first, list)) if *first == id => list.extend(presses),
                        Some(_) => {}
                    }
                }
            }
            _ => {}
        }
    }
    match found {
        Some((id, list)) => ((id != 0).then_some(id), list),
        None => (None, Vec::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The virtual DualSense Edge's descriptor (054c:0df2, through Windows'
    /// hidapi), read on 2026-11-12.
    const EDGE: &str = "05010905a1018501093009310932093509330934150026ff007508950681020600ff0920150026ff0075089501810205010939150025073500463b01651475049501814205091901290f150025017501950f4500650081020600ff0921150025017501950d81020922150026ff003500463b0175089534810285020923150026ff007508952f910285050933150026ff0075089528b10285080934150026ff007508952fb10285090924150026ff0075089513b102850a0925150026ff007508951ab10285200926150026ff007508953fb10285210927150026ff0075089504b10285220940150026ff007508953fb10285800928150026ff007508953fb10285810929150026ff007508953fb1028582092a150026ff0075089509b1028583092b150026ff007508953fb1028584092c150026ff007508953fb1028585092d150026ff0075089502b10285a0092e150026ff0075089501b10285e0092f150026ff007508953fb10285f00930150026ff007508953fb10285f10931150026ff007508953fb10285f20932150026ff007508950fb10285f40935150026ff007508953fb10285f50936150026ff0075089503b102c0";

    #[test]
    fn the_dualsense_describes_its_fifteen_buttons_where_sony_puts_them() {
        let bytes: Vec<u8> = (0..EDGE.len()).step_by(2).map(|i| u8::from_str_radix(&EDGE[i..i + 2], 16).unwrap()).collect();
        let (id, buttons) = buttons(&bytes);
        assert_eq!(id, Some(0x01));
        // the fixed Sony layout the pad crate reads, without the Edge's extras
        assert_eq!(buttons, crate::SONY_BUTTONS[..15].to_vec());
    }
}
