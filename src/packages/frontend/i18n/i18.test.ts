import { editor, jupyter, labels, menu } from "./common";
import { IntlMessage } from "./types";

export type Data = { [key in string]: IntlMessage };

describe("i18n", () => {
  const tests: { data: Data; prefix: string }[] = [
    { data: labels, prefix: "labels." },
    { data: menu, prefix: "menu." },
    { data: editor, prefix: "editor." },
    { data: jupyter.editor, prefix: "jupyter.editor." },
    { data: jupyter.commands, prefix: "jupyter.commands." },
  ] as const;

  tests.forEach(({ data, prefix }) => {
    expect(prefix.endsWith(".")).toBe(true);
    test(`${prefix} should have correct id prefix`, () => {
      for (const k in data) {
        const v = data[k];
        expect(v.id.startsWith(prefix)).toBe(true);
      }
    });
  });
});
