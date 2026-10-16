/**
 * "Find in diff" search (pure): case-insensitive literal matches in the line
 * text of both sides of every file, including collapsed and deferred files.
 */

/** Most matches reported (cmux cap). */
export const MAX_FIND_MATCHES = 9999;

/**
 * @param {object[]} files parsed files
 * @param {string} query
 * @param {(file: object) => object[][]} hunksOf display lines per hunk
 * @returns {{matches: {fileIndex: number, hunkIndex: number, lineIndex: number,
 *   side: "additions" | "deletions", lineNo: number, start: number, end: number}[],
 *   capped: boolean}}
 */
export function searchFiles(files, query, hunksOf) {
  const matches = [];
  const q = String(query || "");
  if (!q) return { matches, capped: false };
  const needle = q.toLowerCase();
  // toLowerCase can change the length of some characters (e.g. "İ"); offsets
  // are only exact when it does not, so such lines are matched per code unit.
  for (const file of files) {
    const hunks = hunksOf(file);
    for (let h = 0; h < hunks.length; h += 1) {
      const lines = hunks[h];
      for (let i = 0; i < lines.length; i += 1) {
        const line = lines[i];
        const text = line.text;
        let hay = text.toLowerCase();
        if (hay.length !== text.length) hay = Array.from(text, (ch) => (ch.toLowerCase().length === ch.length ? ch.toLowerCase() : ch)).join("");
        const side = line.type === "del" ? "deletions" : "additions";
        const lineNo = side === "deletions" ? line.oldNo : line.newNo;
        let from = 0;
        for (;;) {
          const at = hay.indexOf(needle, from);
          if (at < 0) break;
          if (matches.length >= MAX_FIND_MATCHES) return { matches, capped: true };
          matches.push({ fileIndex: file.index, hunkIndex: h, lineIndex: i, side, lineNo, start: at, end: at + q.length });
          from = at + Math.max(1, needle.length);
        }
      }
    }
  }
  return { matches, capped: false };
}

/** Next index in a cyclic list of `count` items (dir = +1 / -1). */
export function cycle(index, count, dir) {
  if (count <= 0) return -1;
  if (index < 0) return dir > 0 ? 0 : count - 1;
  return (((index + dir) % count) + count) % count;
}
