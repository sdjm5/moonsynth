// Arpeggiator — pattern logic.
//
// The arpeggiator runs inside the engine's render loop rather than in the
// host, so steps land on exact sample boundaries instead of wherever a
// JavaScript timer happens to fire. This file holds the two pure pieces:
// expanding the held keys into a note pattern, and advancing through it.
// The stateful part (sample counters, which voice is sounding) lives in
// Synth::render.
//
// Sorting the held keys happens on key events, not per step, so the pattern
// expansion itself allocates nothing: `out` is a caller-owned scratch array.

///|
pub const ARP_UP : Int = 0

///|
pub const ARP_DOWN : Int = 1

///|
pub const ARP_UPDOWN : Int = 2

///|
pub const ARP_RANDOM : Int = 3

///|
pub const ARP_AS_PLAYED : Int = 4

///|
pub const ARP_MODES : Int = 5

///|
/// Expand `ordered` (n notes, already in the order the mode wants to walk:
/// ascending for up/down/up-down/random, key-press order for as-played) into
/// the play pattern by stacking `octaves` transposed copies.
///
/// `out` must have room for n * 4 entries. Returns the pattern length.
pub fn build_pattern(
  ordered : FixedArray[Int],
  n : Int,
  mode : Int,
  octaves : Int,
  out : FixedArray[Int]
) -> Int {
  let oct = if octaves < 1 {
    1
  } else if octaves > 4 {
    4
  } else {
    octaves
  }
  let mut k = 0
  if mode == ARP_DOWN {
    // start from the top octave and walk down
    let mut o = oct - 1
    while o >= 0 {
      let mut i = n - 1
      while i >= 0 {
        out[k] = ordered[i] + 12 * o
        k = k + 1
        i = i - 1
      }
      o = o - 1
    }
  } else {
    for o = 0; o < oct; o = o + 1 {
      for i = 0; i < n; i = i + 1 {
        out[k] = ordered[i] + 12 * o
        k = k + 1
      }
    }
  }
  k
}

///|
/// Advance one step through a pattern of `count` notes.
///
/// `index` is the position just played, `dir` is +1 or -1 (used only by the
/// up-down mode) and `rand` is a caller-supplied random int (used only by the
/// random mode, so the engine stays deterministic under a seed). Returns the
/// next (index, dir).
pub fn next_index(mode : Int, index : Int, count : Int, dir : Int, rand : Int) -> (Int, Int) {
  if count <= 0 {
    return (0, 1)
  }
  match mode {
    ARP_UPDOWN => {
      if count == 1 {
        return (0, dir)
      }
      let mut d = dir
      let mut i = index + d
      if i >= count {
        // hit the top: reflect off the last note and come back down
        d = -1
        i = count - 2
      } else if i < 0 {
        // hit the bottom: reflect off the first note and go back up
        d = 1
        i = 1
      }
      (i, d)
    }
    ARP_RANDOM => {
      let r = rand % count
      (if r < 0 { r + count } else { r }, dir)
    }
    _ => ((index + 1) % count, dir)
  }
}
