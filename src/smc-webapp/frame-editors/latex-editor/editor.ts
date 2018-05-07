/*
Spec for editing LaTeX documents.
*/

import { set } from "../generic/misc";

import { createEditor } from "../frame-tree/editor";

import { PDFJS } from "./pdfjs.tsx";
import { PDFEmbed } from "./pdf-embed.tsx";
import { CodemirrorEditor } from "../code-editor/codemirror-editor";
import { Build } from "./build.tsx";
import { ErrorsAndWarnings } from "./errors-and-warnings.tsx";

import { pdf_path } from "./util";

let pdfjs_buttons = set([
  "print",
  "save",
  "decrease_font_size",
  "increase_font_size",
  "zoom_page_width",
  "zoom_page_height",
  "sync"
]);

const EDITOR_SPEC = {
  cm: {
    short: "LaTeX",
    name: "LaTeX Source Code",
    icon: "code",
    component: CodemirrorEditor,
    buttons: set([
      "print",
      "decrease_font_size",
      "increase_font_size",
      "save",
      "time_travel",
      "replace",
      "find",
      "goto_line",
      "cut",
      "paste",
      "copy",
      "undo",
      "redo",
      "sync",
      "help"
    ]),
    gutters: ["Codemirror-latex-errors"]
  },

  pdfjs_canvas: {
    short: "PDF (canvas)",
    name: "PDF - Canvas",
    icon: "file-pdf-o",
    component: PDFJS,
    buttons: pdfjs_buttons,
    path: pdf_path,
    style: { background: "#525659" },
    renderer: "canvas"
  },

  error: {
    short: "Errors",
    name: "Errors and Warnings",
    icon: "bug",
    component: ErrorsAndWarnings,
    buttons: set([])
  },

  build: {
    short: "Build",
    name: "Build Control",
    icon: "terminal",
    component: Build,
    buttons: set([])
  },

  embed: {
    short: "PDF (native)",
    name: "PDF - Native",
    icon: "file-pdf-o",
    buttons: set(["print", "save"]),
    component: PDFEmbed,
    path: pdf_path
  },

  pdfjs_svg: {
    short: "PDF (svg)",
    name: "PDF - SVG",
    icon: "file-pdf-o",
    component: PDFJS,
    buttons: pdfjs_buttons,
    path: pdf_path,
    style: { background: "#525659" },
    renderer: "svg"
  }

  /*
    latexjs: {
        short: "Preview 1",
        name: "Rough Preview  1 - LaTeX.js",
        icon: "file-pdf-o",
        component: LaTeXJS,
        buttons: set([
            "print",
            "save",
            "decrease_font_size",
            "increase_font_size"
        ])
    },

    peg: {
        short: "Preview 2",
        name: "Rough Preview 2 - PEG.js",
        icon: "file-pdf-o",
        component: PEG,
        buttons: set([
            "print",
            "save",
            "decrease_font_size",
            "increase_font_size"
        ])
    } */
};

export const Editor = createEditor({
  format_bar: true,
  editor_spec: EDITOR_SPEC,
  display_name: "LaTeXEditor"
});
