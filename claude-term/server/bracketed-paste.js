const ESC = '\x1b';
const START = `${ESC}[200~`;
const END = `${ESC}[201~`;

// D7: bracketed paste makes Claude Code's TUI treat a multi-line block as pasted
// text (inserted, not submitted at the first newline). submit appends CR to fire.
export function wrapPaste(body, submit = false) {
  return START + body + END + (submit ? '\r' : '');
}
