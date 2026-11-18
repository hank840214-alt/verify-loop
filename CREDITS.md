# Credits

This project is inspired by two public talks. It is an independent project. Neither speaker nor their employers reviewed, endorsed, or are affiliated with it. Any mistakes are ours.

- Lydia Hallie, ["Rethinking Claude Code Best Practices"](https://youtu.be/vlfCjWuv4es) — permissions by reversibility, sandboxing, hooks that block with exit 2, fresh-context review, risk tiers, "show me the actual output".
- Lauren Tan, ["All Code Is Slop (Except Mine)"](https://youtu.be/O_zcc6Xl12g) — the inverted pyramid (codebase → static analysis → verification → prose → human review), the correction tree, feature maps plus a CLI that drives the real app, formal verification with TLA+ and Lean, "don't automate a bad loop", comments as liabilities.

Several skill steps are adapted from **pstack** (https://github.com/cursor/plugins/tree/main/pstack), Copyright (c) 2026 Lauren Tan, MIT License: the blast-radius check, the seven performance questions, the reproduction standard, the root-cause question and the extended blast-radius list in `skills/debug`; and the task-deepening step, decision log and its independent audit, PR body sections, run-as-user verdict, driver `doctor` command, review-finding triage and lint-exception rule in `skills/verify-loop` (some from pstack's automations/benny skills). The rest of the text and all scripts are original to this project.

The test guard and the commit-bound evidence script came from a reader's comment: "one agent writing both the fix and the test is grading its own exam."

## pstack licence

The adapted steps above are used under this licence:

```
MIT License

Copyright (c) 2026 Lauren Tan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
