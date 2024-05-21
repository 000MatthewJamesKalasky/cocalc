import type { MenuProps } from "antd";
import {
  Alert,
  Button,
  Collapse,
  Divider,
  Dropdown,
  Flex,
  Input,
  InputNumber,
  Popover,
  Space,
  Switch,
  Tag,
} from "antd";
import { throttle } from "lodash";
import React, { useEffect, useRef, useState } from "react";

import { useLanguageModelSetting } from "@cocalc/frontend/account/useLanguageModelSetting";
import { alert_message } from "@cocalc/frontend/alerts";
import { useFrameContext } from "@cocalc/frontend/app-framework";
import {
  LLMNameLink,
  Paragraph,
  RawPrompt,
  Text,
} from "@cocalc/frontend/components";
import AIAvatar from "@cocalc/frontend/components/ai-avatar";
import { Icon } from "@cocalc/frontend/components/icon";
import { NotebookFrameActions } from "@cocalc/frontend/frame-editors/jupyter-editor/cell-notebook/actions";
import { CUTOFF } from "@cocalc/frontend/frame-editors/llm/consts";
import { LLMQueryDropdownButton } from "@cocalc/frontend/frame-editors/llm/llm-query-dropdown";
import LLMSelector, {
  modelToName,
} from "@cocalc/frontend/frame-editors/llm/llm-selector";
import { JupyterActions } from "@cocalc/frontend/jupyter/browser-actions";
import { splitCells } from "@cocalc/frontend/jupyter/llm/split-cells";
import { useProjectContext } from "@cocalc/frontend/project/context";
import { LLMEvent } from "@cocalc/frontend/project/history/types";
import track from "@cocalc/frontend/user-tracking";
import { webapp_client } from "@cocalc/frontend/webapp-client";
import { LLMTools } from "@cocalc/jupyter/types";
import {
  LanguageModel,
  getLLMServiceStatusCheckMD,
  model2vendor,
} from "@cocalc/util/db-schema/llm-utils";
import {
  capitalize,
  getRandomColor,
  plural,
  smallIntegerToEnglishWord,
} from "@cocalc/util/misc";
import { COLORS } from "@cocalc/util/theme";
import { PREVIEW_BOX } from "../../project/page/home-page/ai-generate-document";
import NBViewer from "../nbviewer/nbviewer";
import { Position } from "./types";
import { insertCell } from "./util";

type PrevCells = "none" | number | "all above";

type Cell = { cell_type: "markdown" | "code"; source: string[] };
type Cells = Cell[];

const EXAMPLES: [string, string[]][] = [
  ["Visualize the data.", ["visualize"]],
  ["Run the last function to see it in action.", ["run"]],
  [
    "Combine the code in one large cell and wrap it into a function.",
    ["function"],
  ],
  [
    "Write a summary in a markdown cell explaining the purpose of the code.",
    ["documentation"],
  ],
  [
    "Summarize the key findings of this analysis in a clear and concise paragraph.",
    ["summary"],
  ],
  [
    "Generate a summary statistics table for the entire dataset",
    ["statistics"],
  ],
  ["Perform a principal component analysis (PCA) on the dataset.", ["PCA"]],
  [
    "Conduct a time series analysis on the dataset and extapolate.",
    ["time series"],
  ],
  ["Create an interactive slider for the function.", ["interactive"]],
  [
    "Expand this analysis to include additional statistical tests or visualizations.",
    ["statistics"],
  ],
];

interface AIGenerateCodeCellProps {
  actions: JupyterActions;
  children: React.ReactNode;
  frameActions: React.MutableRefObject<NotebookFrameActions | undefined>;
  id: string;
  setShowAICellGen: (show: Position) => void;
  showAICellGen: Position;
  llmTools?: LLMTools;
}

export function AIGenerateCodeCell({
  actions,
  children,
  frameActions,
  id,
  setShowAICellGen,
  showAICellGen,
  llmTools,
}: AIGenerateCodeCellProps) {
  const { actions: project_actions } = useProjectContext();
  const { project_id, path } = useFrameContext();
  const cancel = useRef<boolean>(false);
  const [querying, setQuerying] = useState<boolean>(false);
  const [model, setModel] = useLanguageModelSetting(project_id);
  const [prompt, setPrompt] = useState<string>("");
  const [cellTypes, setCellTypes] = useState<"code" | "all">("code");
  const [includePreviousCells, setIncludePreviousCells] =
    useState<PrevCells>(2);
  const [error, setError] = useState<string>("");
  const [preview, setPreview] = useState<Cells | null>(null);
  const [attribute, setAttribute] = useState<boolean>(false);
  const promptRef = useRef<HTMLElement>(null);

  const kernel_info = actions.store.get("kernel_info");
  const lang = kernel_info?.get("language") ?? "python";
  const kernel_name = kernel_info?.get("display_name") ?? "Python 3";

  const open = showAICellGen != null;

  useEffect(() => {
    if (!preview && open) {
      promptRef.current?.focus();
    }
  }, [preview, open]);

  function getPrevCodeContents(): string {
    if (includePreviousCells === 0 || showAICellGen == null) return "";
    return getPreviousNonemptyCellContents(
      frameActions.current,
      id,
      showAICellGen,
      includePreviousCells,
      cellTypes,
      lang,
    );
  }

  function insertCells() {
    if (preview == null) {
      console.error("jupyter cell generator: no preview - should never happen");
      return;
    }

    const fa = frameActions.current;
    if (fa == null) {
      throw Error("frame actions must be defined");
    }

    let curCellId = id;

    // only insert the "attribution" cell, if the user wants.
    // What's recorded in any case is an entry in the project's log.
    if (attribute) {
      // This is here to make it clear this was generated by a language model.
      // It could also be a comment in the code cell but for that we would need to know how the
      // comment character of the language.
      const n = preview.length;
      const cellStr = `${smallIntegerToEnglishWord(n)} ${plural(n, "cell")}`;
      const firstCellId = insertCell({
        frameActions,
        actions,
        id,
        position: showAICellGen,
        type: "markdown",
        content: `The following ${cellStr} was generated by [${modelToName(
          model,
        )}](${
          model2vendor(model).url
        }) in response to the prompt:\n\n> ${prompt}\n\n `,
      });

      if (!firstCellId) {
        throw new Error("unable to insert cell");
      }

      fa.set_mode("escape");
      fa.set_md_cell_not_editing(firstCellId);

      curCellId = firstCellId;
    }

    for (let i = 0; i < preview.length; i++) {
      const cell = preview[i];
      const nextCellId = insertCell({
        frameActions,
        actions,
        id: curCellId,
        position: "below",
        type: cell.cell_type,
        content: cell.source.join(""),
      });

      // this shouldn't happen
      if (nextCellId == null) continue;

      fa.set_mode("escape");
      if (cell.cell_type === "markdown") {
        fa.set_md_cell_not_editing(nextCellId);
      }

      curCellId = nextCellId;
    }
  }

  async function queryLanguageModel({
    prevCodeContents,
    includePreviousCells,
  }) {
    if (!prompt.trim()) return;

    const { input, system } = getInput({
      lang,
      kernel_name,
      frameActions,
      model,
      position: showAICellGen,
      prompt,
      prevCodeContents,
    });
    if (!input) {
      return;
    }

    try {
      const tag = `generate-jupyter-cell`;
      track("chatgpt", {
        project_id,
        path,
        tag,
        type: "generate",
        model,
        prev: includePreviousCells,
      });

      const stream = await webapp_client.openai_client.queryStream({
        input,
        project_id,
        path,
        system,
        tag,
        model,
      });

      const updateCells = throttle(
        function (answer) {
          if (cancel.current) return;
          const cells = splitCells(answer);
          setPreview(cells);
        },
        500,
        { leading: true, trailing: true },
      );

      let answer = "";

      stream.on("token", async (token) => {
        if (cancel.current) {
          // we abort this
          stream.removeAllListeners();
          // singal "finalization"
          updateCells(answer);
          return;
        }

        if (token != null) {
          answer += token;
          updateCells(answer);
        } else {
          // reply emits undefined text *once* when done, so done at this point.
          updateCells(answer);
          setQuerying(false);
        }
      });

      stream.on("error", (err) => {
        setError(
          `Error generating code cell: ${err}\n\n${getLLMServiceStatusCheckMD(
            model2vendor(model).name,
          )}.`,
        );
        setQuerying(false);
      });

      stream.emit("start");
    } catch (err) {
      setPreview(null);
      alert_message({
        type: "error",
        title: "Problem generating code cell",
        message: `${err}`,
      });
    }
  }

  function doQuery(prevCodeContents: string) {
    cancel.current = false;
    setQuerying(true);
    if (showAICellGen == null) return;
    queryLanguageModel({
      prevCodeContents,
      includePreviousCells,
    });

    // we also log this
    const event: LLMEvent = {
      event: "llm",
      usage: "jupyter-generate-cell",
      model,
      path,
    };
    project_actions?.log(event);
  }

  function renderExamples() {
    const items: MenuProps["items"] = EXAMPLES.map(([ex, tags], idx) => {
      const label = (
        <Flex gap={"5px"} justify="space-between">
          <Flex>{ex} </Flex>
          <Flex>
            {tags.map((tag) => (
              <Tag key={tag} color={getRandomColor(tag)}>
                {tag}
              </Tag>
            ))}
          </Flex>
        </Flex>
      );
      return {
        key: `${idx}`,
        label,
        onClick: () => {
          setPrompt(ex);
        },
      };
    });
    return (
      <Paragraph>
        <Dropdown menu={{ items }} trigger={["click"]}>
          <Button style={{ width: "100%" }}>
            <Space>
              <Icon name="magic" />
              Pick an example
              <Icon name="caret-down" />
            </Space>
          </Button>
        </Dropdown>
      </Paragraph>
    );
  }

  function renderContext() {
    const cellStr = `${cellTypes === "code" ? "code " : ""} cell`;
    return (
      <>
        <Divider orientation="left">
          <Text>Context</Text>
        </Divider>
        <Paragraph>
          <Flex dir="horizontal" gap="10px" align="center" justify="center">
            <Flex flex={1}>
              <div>
                Include{" "}
                {typeof includePreviousCells === "number" ? (
                  <>
                    previous{" "}
                    <InputNumber
                      min={0}
                      max={10}
                      size={"small"}
                      value={includePreviousCells}
                      onChange={(value) => setIncludePreviousCells(value ?? 1)}
                    />{" "}
                    {plural(
                      includePreviousCells,
                      `${cellStr}.`,
                      `${cellStr}s.`,
                    )}
                  </>
                ) : includePreviousCells === "all above" ? (
                  `all previous ${cellStr}s`
                ) : (
                  `no ${cellStr}s`
                )}
              </div>
            </Flex>
            <Flex flex={0}>
              {["none", 1, 2, 3, 5, 10, "all above"].map((i: PrevCells) => {
                const c = getRandomColor(`${i}`);
                return (
                  <Tag
                    key={i}
                    color={c}
                    style={{ cursor: "pointer" }}
                    onClick={() => setIncludePreviousCells(i)}
                  >
                    {i}
                  </Tag>
                );
              })}
            </Flex>
          </Flex>
        </Paragraph>
        <Paragraph>
          <Flex align="center" gap="10px">
            <Flex flex={0}>
              <Switch
                defaultChecked={cellTypes === "all"}
                onChange={(val) => setCellTypes(val ? "all" : "code")}
                unCheckedChildren={"Code cells"}
                checkedChildren={"All Cells"}
              />
            </Flex>
            <Flex flex={1}>
              <Text type="secondary">
                Include only code cells, or all types of cells.
              </Text>
            </Flex>
          </Flex>
        </Paragraph>
      </>
    );
  }

  function insert() {
    insertCells();
    setPreview(null);
    setShowAICellGen(null);
  }

  function renderContentPreview() {
    const cellStr = plural(preview?.length ?? 0, "cell");
    return (
      <>
        <Paragraph>
          This is a preview of the generated content.{" "}
          {querying ? (
            <Text strong>Please wait until it is fully generated...</Text>
          ) : (
            <Text strong>
              Cells are generated. You can now{" "}
              <Button
                size="small"
                onClick={insert}
                type="primary"
                disabled={querying}
              >
                insert the {cellStr}
              </Button>
              .
            </Text>
          )}
        </Paragraph>
        <Paragraph>
          <NBViewer
            content={JSON.stringify(
              { metadata: { kernelspec: kernel_info }, cells: preview },
              null,
              2,
            )}
            fontSize={undefined}
            style={PREVIEW_BOX}
            cellListStyle={{
              transform: "scale(0.9)",
              transformOrigin: "top left",
              width: "110%",
            }}
            scrollBottom={true}
          />
        </Paragraph>
        <Paragraph>
          <Flex align="center" gap="10px">
            <Flex flex={0}>
              <Switch
                value={attribute}
                onChange={(val) => setAttribute(val)}
                unCheckedChildren={"Only cells"}
                checkedChildren={"With attribution"}
              />
            </Flex>
            <Flex flex={1}>
              <Text type="secondary">
                Add a cell attributing the language model and the prompt.
              </Text>
            </Flex>
          </Flex>
        </Paragraph>
        <Paragraph style={{ textAlign: "center", marginTop: "15px" }}>
          <Space size="middle">
            <Button
              size="large"
              onClick={() => {
                cancel.current = true;
                setPreview(null);
                setQuerying(false);
              }}
            >
              <Icon name="arrow-left" /> Discard
            </Button>
            <Button onClick={insert} type="primary" disabled={querying}>
              <Icon name="plus" /> Insert {capitalize(cellStr)}
            </Button>
          </Space>
        </Paragraph>
      </>
    );
  }

  function renderContentDialog() {
    const prevCodeContents = getPrevCodeContents();

    const { input } = getInput({
      frameActions,
      prompt,
      lang,
      kernel_name,
      position: showAICellGen,
      model,
      prevCodeContents,
    });

    const empty = prompt.trim() == "";
    return (
      <>
        <Paragraph type={empty ? "danger" : undefined}>
          Describe, what the new cell should do:
        </Paragraph>
        <Paragraph>
          <Input.TextArea
            ref={promptRef}
            allowClear
            autoFocus
            value={prompt}
            status={empty ? "error" : undefined}
            onChange={(e) => {
              setPrompt(e.target.value);
            }}
            placeholder="Describe the new cell..."
            onPressEnter={(e) => {
              if (!e.shiftKey) return;
              doQuery(prevCodeContents);
            }}
            autoSize={{ minRows: 2, maxRows: 6 }}
          />
        </Paragraph>
        {renderExamples()}
        {empty ? undefined : renderContext()}
        {input?.trim() ? (
          <>
            <Divider />
            <Paragraph type="secondary">
              A prompt to generate one or more cells based on your description
              and context will be sent to the <LLMNameLink model={model} />{" "}
              language model.
            </Paragraph>
            <Collapse
              items={[
                {
                  key: "1",
                  label: (
                    <>Click to see what will be sent to {modelToName(model)}.</>
                  ),
                  children: (
                    <RawPrompt
                      input={input}
                      style={{ border: "none", padding: "0", margin: "0" }}
                    />
                  ),
                },
              ]}
            />
          </>
        ) : undefined}
        <Paragraph style={{ textAlign: "center", marginTop: "30px" }}>
          <Space size="large">
            <Button onClick={() => setShowAICellGen(null)}>Cancel</Button>
            <LLMQueryDropdownButton
              disabled={!prompt.trim()}
              loading={querying}
              onClick={() => doQuery(prevCodeContents)}
              llmTools={llmTools}
              task="Generate using"
            />
          </Space>
        </Paragraph>
        {error ? <Alert type="error" message={error} /> : undefined}
      </>
    );
  }

  // called, when actually displayed
  function renderContent() {
    return (
      <div style={{ maxWidth: "min(650px, 90vw)" }}>
        {preview ? renderContentPreview() : renderContentDialog()}
      </div>
    );
  }

  return (
    <Popover
      placement="bottom"
      title={() => (
        <div style={{ fontSize: "18px" }}>
          <AIAvatar size={22} /> Generate code cell using{" "}
          <LLMSelector
            project_id={project_id}
            model={model}
            setModel={setModel}
          />
          <Button
            onClick={() => setShowAICellGen(null)}
            type="text"
            style={{ float: "right", color: COLORS.GRAY_M }}
          >
            <Icon name="times" />
          </Button>
        </div>
      )}
      open={open}
      content={renderContent}
      trigger={[]}
      destroyTooltipOnHide
    >
      {children}
    </Popover>
  );
}

interface GetInputProps {
  frameActions: React.MutableRefObject<NotebookFrameActions | undefined>;
  model: LanguageModel;
  position: Position;
  prompt: string;
  prevCodeContents: string;
  lang: string;
  kernel_name: string;
}

function getInput({
  frameActions,
  prompt,
  prevCodeContents,
  lang,
  kernel_name,
}: GetInputProps): {
  input: string;
  system: string;
} {
  if (!prompt?.trim()) {
    return { input: "", system: "" };
  }
  if (frameActions.current == null) {
    console.warn(
      "Unable to create cell due to frameActions not being defined.",
    );
    return { input: "", system: "" };
  }
  const prevCode = prevCodeContents
    ? `\n\nThe context after which to insert the cells is:\n\n<context>\n${prevCodeContents}\n\</context>`
    : "";

  return {
    input: `Create a new code cell for a Jupyter Notebook.\n\nKernel: "${kernel_name}".\n\nProgramming language: "${lang}".\n\The entire code cell must be in a single code block. Enclose this block in triple backticks. Do not say what the output will be. Add comments as code comments. ${prevCode}\n\nThe new cell should do the following:\n\n${prompt}`,
    system: `Return a single code block in the language "${lang}". Be brief.`,
  };
}

function getPreviousNonemptyCellContents(
  actions: NotebookFrameActions | undefined,
  id: string,
  position,
  prevCells: PrevCells,
  cellTypes: "all" | "code" | "markdown" = "code",
  lang,
): string {
  if (actions == null) return "";
  if (prevCells === "none") return "";
  const jupyterActionsStore = actions?.jupyter_actions.store;
  const start = position === "below" ? 0 : -1;
  let delta: number = start;
  const cells: string[] = [];
  let length = 0;

  while (true) {
    const prevId = jupyterActionsStore.get_cell_id(delta, id);
    if (!prevId) break;
    const prevCell = actions.get_cell_by_id(prevId);
    if (!prevCell) break;
    const code = actions.get_cell_input(prevId)?.trim();
    const cellType = prevCell.get("cell_type", "code");
    if (code && (cellTypes === "all" || cellType === cellTypes)) {
      // we found a cell of given type
      length += code.length;
      if (length > CUTOFF) break;
      cells.unshift(
        cellTypes === "all" && cellType === "code"
          ? `\`\`\`${lang}\n${code}\n\`\`\``
          : code,
      );
      if (typeof prevCells === "number") {
        prevCells -= 1;
        if (prevCells <= 0) break;
      }
    }
    delta -= 1;
  }
  return cells.join("\n\n");
}
