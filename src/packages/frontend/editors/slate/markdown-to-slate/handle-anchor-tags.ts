/*
 *  This file is part of CoCalc: Copyright © 2020 Sagemath, Inc.
 *  License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
 */

/*
This is very similar to handle-open and handle-close for handling
big block opening and closing tokens.  However, it's just for the
special case of html anchor tags.

TODO: With this implementation of our parser, if you do this

```md
Consider <a>foo

and bar (this is a new block).
```

then the anchor tag never gets closed hence nothing is emitting in the transition
to slate.  It would make a LOT more sense to automatically close it at the end of
its containing block.

*/


import { register } from "./register";
import { Descendant } from "slate";
import { State } from "./types";
import { getMarkdownToSlate } from "../elements/register";
import { parse } from "./parse";
import stringify from "json-stable-stringify";
import { ensureTextStartAndEnd } from "./normalize";
import $ from "cheerio";

// handling open anchor tag
register(({ token, state }) => {
  if (state.anchor != null) return; // already handling an anchor tag
  if (
    token.type != "html_inline" ||
    !token.content.toLowerCase().trim().startsWith("<a")
  ) {
    // definitely not an anchor tag
    return;
  }

  // starting an anchor tag
  state.contents = [];
  state.anchor = token;
  const x = $(token.content);
  state.attrs = [];
  // todo: we could implement target explicitly, and also could implement style=,
  // though github doesn't and style is an XSS vector so complicated
  for (const attr of ["href", "title"]) {
    const val = x.attr(attr);
    if (val != null) {
      state.attrs.push([attr, val]);
    }
  }
  state.nesting = 0;
  return [];
});

const type = "link";

// handle gathering everything between anchor tags and
// processing result when we hit a closing anchor tag.
register(({ token, state, cache }) => {
  if (state.anchor == null) return; // not currently handling an anchor tag
  if (state.contents == null) {
    throw Error("bug -- state.contents must not be null");
  }

  if (token.type == "html_inline") {
    const x = token.content.toLowerCase().trim();
    if (x.startsWith("<a")) {
      // nesting
      state.nesting += 1;
    } else if (x == "</a>") {
      if (state.nesting > 0) {
        state.nesting -= 1;
      } else {
        // Not nested, so done: parse the accumulated array of children
        // using a new state:
        const child_state: State = {
          nesting: 0,
          marks: state.marks,
          lines: state.lines,
        };
        const children: Descendant[] = [];
        let markdown = "";
        for (const token2 of state.contents) {
          for (const node of parse(token2, child_state, cache)) {
            children.push(node);
          }
          markdown += child_state.markdown ?? "";
        }
        ensureTextStartAndEnd(children);
        const markdownToSlate = getMarkdownToSlate(type);
        const node = markdownToSlate({
          type,
          children,
          state,
          cache,
        });
        if (node == null) {
          // this won't happen, but it's for typescript
          return [];
        }
        if (cache != null && markdown) {
          cache[stringify(node)] = markdown;
        }

        delete state.contents;
        delete state.anchor;
        delete state.attrs;
        return [node];
      }
    }
  }

  // currently gathering between anchor tags:
  state.contents.push(token);
  return []; // we handled this token.
});
