/*
Render the canvas, which is by definition all of the drawing elements
in the whiteboard.

This is NOT an HTML5 canvas.  It has nothing do with that.   We define
"the whiteboard" as everything -- the controls, settings, etc. -- and
the canvas as the area where the actual drawing appears.

NOTE: This component assumes that when it is first mounted that elements
is actually what it will be for the initial load, so that it can properly
set the center position.  Do not create with elements=[], then the real
elements.

COORDINATES:

Functions below that depend on the coordinate system should
be named ending with either "Data", "Window" or "Viewport",
depending on what coordinates they use.  Those coordinate
systems are defined below.

data coordinates:
- what all the elements use in defining themselves.
- this is an x,y infinite plane, with of course the
  x-axis going down (computer graphics, after all)
- objects also have an arbitrary z coordinate

window coordinates:
- this is the div we're drawing everything to the screen using
- when we draw an element on the screen, we used position absolute
with window coordinates.
- also x,y with x-axis going down.  However, negative
  coordinates can never be visible.
- scrolling the visible window does not change these coordinates.
- this is related to data coordinates by a translation followed
  by scaling.
- we also translate all z-coordinates to be in an explicit interval [0,MAX]
  via an increasing (but not necessarily linear!) function.

viewport coordinates:
- this is the coordinate system used when clicking with the mouse
  and getting an event e.clientX, e.clientY.  The upper left point (0,0)
  is the upper left corner of the browser window.
- this is related to window coordinates by translation, where the parameters
  are the position of the canvas div and its top,left offset attributes.
  Thus the transform back and forth between window and viewport coordinates
  is extra tricky, because it can change any time at any time!
*/

import { useWheel } from "@use-gesture/react";
import {
  ClipboardEvent,
  ReactNode,
  MutableRefObject,
  useEffect,
  useMemo,
  useRef,
  useState,
  CSSProperties,
} from "react";
import { Element, ElementType, ElementsMap, Point, Rect } from "./types";
import { Tool, TOOLS } from "./tools/spec";
import RenderElement from "./elements/render";
import RenderEdge from "./elements/edge";
import Focused from "./focused";
import {
  SELECTED_BORDER_COLOR,
  SELECTED_BORDER_TYPE,
  SELECTED_BORDER_WIDTH,
} from "./elements/style";
import NotFocused from "./not-focused";
import Position from "./position";
import { useFrameContext } from "./hooks";
import usePinchToZoom from "@cocalc/frontend/frame-editors/frame-tree/pinch-to-zoom";
import Grid from "./elements/grid";
import {
  centerOfRect,
  compressPath,
  zoomToFontSize,
  fontSizeToZoom,
  ZOOM100,
  getPageSpan,
  getPosition,
  fitRectToRect,
  getOverlappingElements,
  getTransforms,
  pointEqual,
  pointRound,
  pointsToRect,
  rectEqual,
  rectSpan,
  MAX_ELEMENTS,
} from "./math";
import { throttle } from "lodash";
import Draggable from "react-draggable";
import { clearCanvas, drawCurve, getMaxCanvasSizeScale } from "./elements/pen";
import { getElement } from "./tools/tool-panel";
import { encodeForCopy, decodeForPaste } from "./tools/clipboard";
import { aspectRatioToNumber } from "./tools/frame";

import Cursors from "./cursors";

const penDPIFactor = window.devicePixelRatio;

const MIDDLE_MOUSE_BUTTON = 1;

interface Props {
  elements: Element[];
  elementsMap?: ElementsMap;
  font_size?: number;
  scale?: number; // use this if passed in; otherwise, deduce from font_size.
  selection?: Set<string>;
  selectedTool?: Tool;
  margin?: number;
  readOnly?: boolean;
  tool?: Tool;
  evtToDataRef?: MutableRefObject<Function | null>;
  isNavigator?: boolean; // is the navigator, so hide the grid, don't save window, don't scroll, don't move
  style?: CSSProperties;
  previewMode?: boolean; // Use a blue box preview, instead of the actual elements.
  cursors?: { [id: string]: { [account_id: string]: any[] } };
}

export default function Canvas({
  elements,
  elementsMap,
  font_size,
  scale: scale0,
  selection,
  margin = 2000,
  readOnly,
  selectedTool,
  evtToDataRef,
  isNavigator,
  style,
  previewMode,
  cursors,
}: Props) {
  const frame = useFrameContext();
  const canvasScale = scale0 ?? fontSizeToZoom(font_size);

  const gridDivRef = useRef<any>(null);
  const canvasRef = useRef<any>(null);
  const scaleDivRef = useRef<any>(null);

  const firstOffsetRef = useRef<any>({
    scale: 1,
    offset: { x: 0, y: 0 },
    mouse: { x: 0, y: 0 },
  });
  usePinchToZoom({
    target: canvasRef,
    min: 2,
    max: 50,
    throttleMs: 100,
    onZoom: ({ fontSize, first }) => {
      if (first) {
        const rect = scaleDivRef.current?.getBoundingClientRect();
        const mouse =
          rect != null && mouseMoveRef.current
            ? {
                x: mouseMoveRef.current.clientX - rect.left,
                y: mouseMoveRef.current.clientY - rect.top,
              }
            : { x: 0, y: 0 };
        firstOffsetRef.current = {
          offset: offset.get(),
          scale: scale.get(),
          mouse,
        };
      }

      const curScale = fontSizeToZoom(fontSize);
      scale.set(curScale);

      const { mouse } = firstOffsetRef.current;
      const tx = mouse.x * curScale - mouse.x * firstOffsetRef.current.scale;
      const ty = mouse.y * curScale - mouse.y * firstOffsetRef.current.scale;
      const x =
        firstOffsetRef.current.offset.x - tx / firstOffsetRef.current.scale;
      const y =
        firstOffsetRef.current.offset.y - ty / firstOffsetRef.current.scale;
      offset.set({ x, y });
      scale.setFontSize();
    },
  });

  useEffect(() => {
    if (scaleRef.current != canvasScale) {
      // - canvasScale changed due to something external, rather than
      // usePinchToZoom above, since when changing due to pinch zoom,
      // scaleRef has already been set before this call here happens.
      // - We want to preserve the center of the canvas on zooming.
      // - Code below is almost identical to usePinch code above,
      //   except we compute clientX and clientY that would get if mouse
      //   was in the center.
      const rect = scaleDivRef.current?.getBoundingClientRect();
      const rect2 = canvasRef.current?.getBoundingClientRect();
      const clientX = rect2.left + rect2.width / 2;
      const clientY = rect2.top + rect2.height / 2;
      const mouse =
        rect != null && mouseMoveRef.current
          ? {
              x: clientX - rect.left,
              y: clientY - rect.top,
            }
          : { x: 0, y: 0 };
      const tx = mouse.x * canvasScale - mouse.x * scaleRef.current;
      const ty = mouse.y * canvasScale - mouse.y * scaleRef.current;
      offset.translate({ x: tx / scaleRef.current, y: ty / scaleRef.current });
    }
    scale.set(canvasScale);
    saveViewport();
  }, [canvasScale]);

  const scaleRef = useRef<number>(canvasScale);
  const scale = useMemo(() => {
    return {
      set: (scale: number) => {
        if (scaleDivRef.current == null) return;
        scaleRef.current = scale;
        scaleDivRef.current.style.setProperty("transform", `scale(${scale})`);
      },
      get: () => {
        return scaleRef.current;
      },
      setFontSize: throttle(() => {
        frame.actions.set_font_size(frame.id, zoomToFontSize(scaleRef.current));
      }, 250),
    };
  }, [scaleRef, scaleDivRef, frame.id]);

  const offset = useMemo(() => {
    const set = ({ x, y }: Point) => {
      if (isNavigator) return;
      const e = scaleDivRef.current;
      if (e == null) return;
      const c = canvasRef.current;
      const rect = c?.getBoundingClientRect();
      if (rect == null) return;
      const left = Math.min(
        0,
        Math.max(x, -e.offsetWidth * scaleRef.current + rect.width)
      );
      const top = Math.min(
        0,
        Math.max(y, -e.offsetHeight * scaleRef.current + rect.height)
      );

      e.style.setProperty("left", `${left}px`);
      e.style.setProperty("top", `${top}px`);
      saveViewport();
    };

    return {
      set,
      get: () => {
        const e = scaleDivRef.current;
        if (e == null) return { x: 0, y: 0 };
        return { x: e.offsetLeft, y: e.offsetTop };
      },
      translate: ({ x, y }: Point) => {
        const e = scaleDivRef.current;
        if (e == null) return;
        set({ x: -x + e.offsetLeft, y: -y + e.offsetTop });
      },
    };
  }, [scaleDivRef, canvasRef]);

  useWheel(
    (state) => {
      if (state.event.ctrlKey) return; // handled elsewhere
      offset.translate({ x: state.delta[0], y: state.delta[1] });
    },
    {
      target: canvasRef,
    }
  );

  const innerCanvasRef = useRef<any>(null);

  const canvasScaleRef = useRef<number>(1);
  const transforms = useMemo(() => {
    // TODO: if tool is not select, should we exclude hidden elements in computing this...?
    const t = getTransforms(elements, margin);
    // also update the canvas scale, which is needed to keep
    // the canvas preview layer (for the pen) from getting too big
    // and wasting memory.
    canvasScaleRef.current = getMaxCanvasSizeScale(
      penDPIFactor * t.width,
      penDPIFactor * t.height
    );
    return t;
  }, [elements, margin]);

  const mousePath = useRef<{ x: number; y: number }[] | null>(null);
  const handRef = useRef<{
    start: Point;
    clientX: number;
    clientY: number;
  } | null>(null);
  const ignoreNextClick = useRef<boolean>(false);
  // position of mouse right now not transformed in any way,
  // just in case we need it. This is clientX, clientY off
  // of the canvas div.
  const mousePos = useRef<{ clientX: number; clientY: number } | null>(null);

  // this is in terms of window coords:
  const [selectRect, setSelectRect] = useState<{
    x: number;
    y: number;
    w: number;
    h: number;
  } | null>(null);

  const penCanvasRef = useRef<any>(null);

  // Whenever the data <--> window transform params change,
  // ensure the current center of the viewport is preserved
  // or if the mouse is in the viewport, maintain its position.
  const lastViewport = useRef<Rect | undefined>(undefined);
  const lastMouseRef = useRef<any>(null);
  const mouseMoveRef = useRef<any>(null);

  // If the viewport changes, but not because we just set it,
  // then we move our current center displayed viewport to match that.
  // This happens, e.g., when the navmap is clicked on or dragged.
  useEffect(() => {
    if (isNavigator) return;
    const viewport = frame.desc.get("viewport")?.toJS();
    if (viewport == null || rectEqual(viewport, lastViewport.current)) {
      return;
    }
    // request to change viewport.
    setCenterPositionData(centerOfRect(viewport));
  }, [frame.desc.get("viewport")]);

  // Handle setting a center position for the visible window
  // by restoring last known viewport center on first mount.
  // The center is nice since it is meaningful even if browser
  // viewport has changed (e.g., font size, window size, etc.)
  useEffect(() => {
    if (isNavigator) return;
    const viewport = frame.desc.get("viewport")?.toJS();
    if (viewport == null) {
      // document was never opened before in this browser,
      // so fit to screen.
      frame.actions.fitToScreen(frame.id, true);
      return;
    }
    const center = centerOfRect(viewport);
    if (center != null) {
      setCenterPositionData(center);
    }
  }, []);

  function getToolElement(tool): Partial<Element> {
    const elt = getElement(tool, frame.desc.get(`${tool}Id`));
    if (elt.data?.aspectRatio) {
      const ar = aspectRatioToNumber(elt.data.aspectRatio);
      if (elt.w == null) {
        elt.w = 500;
      }
      elt.h = elt.w / (ar != 0 ? ar : 1);
    }
    return elt;
  }

  // get window coordinates of what is currently displayed in the exact
  // center of the viewport.
  function getCenterPositionWindow(): { x: number; y: number } | undefined {
    const c = canvasRef.current;
    if (c == null) return;
    const rect = c.getBoundingClientRect();
    if (rect == null) return;
    const d = scaleDivRef.current;
    if (d == null) return;
    // the current center of the viewport, but in window coordinates, i.e.,
    // absolute coordinates into the canvas div.
    const { x, y } = offset.get();
    return {
      x: -x + rect.width / 2,
      y: -y + rect.height / 2,
    };
  }

  // set center position in Data coordinates.
  function setCenterPositionData({ x, y }: Point): void {
    const t = dataToWindow({ x, y });
    const cur = getCenterPositionWindow();
    if (cur == null) return;
    const delta_x = t.x - cur.x;
    const delta_y = t.y - cur.y;
    offset.translate({ x: delta_x, y: delta_y });
  }

  // when fitToScreen is true, compute data then set font_size to
  // get zoom (plus offset) so everything is visible properly
  // on the page; also set fitToScreen back to false in
  // frame tree data.
  useEffect(() => {
    if (isNavigator || !frame.desc.get("fitToScreen")) return;
    try {
      if (elements.length == 0) {
        // Special case -- the screen is blank; don't want to just
        // maximal zoom in on the center!
        setCenterPositionData({ x: 0, y: 0 });
        lastViewport.current = getViewportData();
        frame.actions.set_font_size(frame.id, Math.floor(ZOOM100));
        return;
      }
      const viewport = getViewportData();
      if (viewport == null) return;
      const rect = rectSpan(elements);
      const offset = 50 / canvasScale; // a little breathing room for the toolbar
      setCenterPositionData({
        x: rect.x + rect.w / 2 - offset,
        y: rect.y + rect.h / 2,
      });
      let { scale } = fitRectToRect(rect, viewport);
      if (scale != 1) {
        // put bounds on the *automatic* zoom we get from fitting to rect,
        // since could easily get something totally insane, e.g., for a dot.
        let newFontSize = Math.floor((font_size ?? ZOOM100) * scale);
        if (newFontSize < ZOOM100 * 0.2) {
          newFontSize = Math.round(ZOOM100 * 0.2);
        } else if (newFontSize > ZOOM100 * 5) {
          newFontSize = Math.round(ZOOM100 * 5);
        }
        // ensure lastViewport is up to date before zooming.
        lastViewport.current = getViewportData();
        frame.actions.set_font_size(frame.id, newFontSize);
      }
    } finally {
      frame.actions.fitToScreen(frame.id, false);
    }
  }, [frame.desc.get("fitToScreen")]);

  let selectionHandled = false;
  function processElement(element, isNavRectangle = false) {
    const { id, rotate } = element;
    const { x, y, z, w, h } = getPosition(element);
    const t = transforms.dataToWindowNoScale(x, y, z);

    if (element.hide != null) {
      // element is hidden...
      if (readOnly || selectedTool != "select" || element.hide.frame) {
        // do not show at all for any tool except select, or if hidden as
        // part of a frame.
        return;
      }
      // Now it will get rendered, but in a minified way.
    }

    if (element.type == "edge") {
      if (elementsMap == null) return; // need elementsMap to render edges efficiently.
      // NOTE: edge doesn't handle showing edit bar for selection in case of one selected edge.
      return (
        <RenderEdge
          key={element.id}
          element={element}
          elementsMap={elementsMap}
          transforms={transforms}
          selected={selection?.has(element.id)}
          previewMode={previewMode}
          onClick={(e) => {
            frame.actions.setSelection(
              frame.id,
              element.id,
              e.altKey || e.shiftKey || e.metaKey ? "add" : "only"
            );
          }}
        />
      );
    }

    if (previewMode && !isNavRectangle) {
      if (element.type == "edge") {
        // ignore edges in preview mode.
        return;
      }
      // This just shows blue boxes in the nav map, instead of actually
      // rendering something. It's probably faster and easier,
      // but really rendering something is much more usable.  Sometimes this
      // is more useful, e.g., with small text.  User can easily toggle to
      // get this by clicking the map icon.
      return (
        <Position key={id} x={t.x} y={t.y} z={0} w={w} h={h}>
          <div
            style={{
              width: "100%",
              height: "100%",
              opacity: "0.8",
              background: "#9fc3ff",
              pointerEvents: "none",
              touchAction: "none",
            }}
          ></div>
        </Position>
      );
    }

    const selected = selection?.has(id);
    const focused = !!(selected && selection?.size === 1);
    if (focused) {
      selectionHandled = true;
    }

    let elt = (
      <RenderElement
        element={element}
        focused={focused}
        canvasScale={canvasScale}
        readOnly={readOnly || isNavigator}
        cursors={cursors?.[id]}
      />
    );
    if (!isNavRectangle && (element.style || selected || isNavigator)) {
      elt = (
        <div
          style={{
            ...element.style,
            ...(selected
              ? {
                  cursor: "text",
                  border: `${
                    SELECTED_BORDER_WIDTH / canvasScale
                  }px ${SELECTED_BORDER_TYPE} ${SELECTED_BORDER_COLOR}`,
                  marginLeft: `-${SELECTED_BORDER_WIDTH / canvasScale}px`,
                  marginTop: `-${SELECTED_BORDER_WIDTH / canvasScale}px`,
                }
              : undefined),
            width: "100%",
            height: "100%",
          }}
        >
          {elt}
        </div>
      );
    }
    if (rotate) {
      elt = (
        <div
          style={{
            transform: `rotate(${
              typeof rotate != "number" ? parseFloat(rotate) : rotate
            }rad)`,
            transformOrigin: "center",
            width: "100%",
            height: "100%",
          }}
        >
          {elt}
        </div>
      );
    }

    if (focused) {
      return (
        <Focused
          key={id}
          canvasScale={canvasScale}
          element={element}
          allElements={elements}
          selectedElements={[element]}
          transforms={transforms}
          readOnly={readOnly}
          cursors={cursors?.[id]}
        >
          {elt}
        </Focused>
      );
    } else {
      return (
        <Position
          key={id}
          x={t.x}
          y={t.y}
          z={isNavRectangle ? z : t.z}
          w={w}
          h={h}
        >
          <Cursors cursors={cursors?.[id]} canvasScale={canvasScale} />
          <NotFocused id={id} selectable={selectedTool == "select"}>
            {elt}
          </NotFocused>
        </Position>
      );
    }
  }

  const v: ReactNode[] = [];

  for (const element of elements) {
    const x = processElement(element);
    if (x != null) {
      v.push(x);
    }
  }

  if (!selectionHandled && selection != null && selection.size >= 1) {
    // create a virtual selection element that
    // contains the region spanned by all elements
    // in the selection.
    // TODO: This could be optimized with better data structures...
    const selectedElements = elements.filter((element) =>
      selection.has(element.id)
    );
    const selectedRects: Element[] = [];
    let multi: undefined | boolean = undefined;
    for (const element of selectedElements) {
      if (element.type == "edge" && elementsMap != null) {
        multi = true;
        // replace edges by source/dest elements.
        for (const x of ["from", "to"]) {
          const a = elementsMap?.get(element.data?.[x] ?? "")?.toJS();
          if (a != null) {
            selectedRects.push(a);
          }
        }
      }
      selectedRects.push(element);
    }
    const { xMin, yMin, xMax, yMax } = getPageSpan(selectedRects, 0);
    const element = {
      type: "selection" as ElementType,
      id: "selection",
      x: xMin,
      y: yMin,
      w: xMax - xMin + 1,
      h: yMax - yMin + 1,
      z: 0,
    };
    v.push(
      <Focused
        key={"selection"}
        canvasScale={canvasScale}
        element={element}
        allElements={elements}
        selectedElements={selectedElements}
        transforms={transforms}
        readOnly={readOnly}
        multi={multi}
      >
        <RenderElement element={element} canvasScale={canvasScale} focused />
      </Focused>
    );
  }

  if (isNavigator) {
    // The navigator rectangle
    const visible = frame.desc.get("viewport")?.toJS();
    if (visible) {
      v.unshift(
        <Draggable
          key="nav"
          position={{ x: 0, y: 0 }}
          scale={canvasScale}
          onStart={() => {
            ignoreNextClick.current = true;
          }}
          onStop={(_, data) => {
            if (visible == null) return;
            const { x, y } = centerOfRect(visible);
            frame.actions.setViewportCenter(frame.id, {
              x: x + data.x,
              y: y + data.y,
            });
          }}
        >
          <div style={{ zIndex: MAX_ELEMENTS + 1, position: "absolute" }}>
            {processElement(
              {
                id: "nav-frame",
                ...visible,
                z: MAX_ELEMENTS + 1,
                type: "frame",
                data: { color: "#888", radius: 0.5 },
                style: {
                  background: "rgb(200,200,200,0.2)",
                },
              },
              true
            )}
          </div>
        </Draggable>
      );
    }
  }

  /****************************************************/
  // Full coordinate transforms back and forth!
  // Note, transforms has coordinate transforms without scaling
  // in it, since that's very useful. However, these two
  // below are the full transforms.

  function viewportToWindow({ x, y }: Point): Point {
    const c = canvasRef.current;
    if (c == null) return { x: 0, y: 0 };
    const rect = c.getBoundingClientRect();
    if (rect == null) return { x: 0, y: 0 };
    const off = offset.get();
    return {
      x: -off.x + x - rect.left,
      y: -off.y + y - rect.top,
    };
  }

  // window coords to data coords
  function windowToData({ x, y }: Point): Point {
    return transforms.windowToDataNoScale(
      x / scaleRef.current,
      y / scaleRef.current
    );
  }
  function dataToWindow({ x, y }: Point): Point {
    const p = transforms.dataToWindowNoScale(x, y);
    p.x *= scaleRef.current;
    p.y *= scaleRef.current;
    return { x: p.x, y: p.y };
  }
  /****************************************************/
  // The viewport in *data* coordinates
  function getViewportData(): Rect | undefined {
    const v = getViewportWindow();
    if (v == null) return;
    const { x, y } = windowToData(v);
    return { x, y, w: v.w / scaleRef.current, h: v.h / scaleRef.current };
  }
  // The viewport in *window* coordinates
  function getViewportWindow(): Rect | undefined {
    const c = canvasRef.current;
    if (c == null) return;
    const { width: w, height: h } = c.getBoundingClientRect();
    if (!w || !h) {
      // this happens when canvas is hidden from screen (e.g., background tab).
      return;
    }
    const { x, y } = offset.get();
    return { x: -x, y: -y, w, h };
  }

  // convert mouse event to coordinates in data space
  function evtToData(e): Point {
    if (e.changedTouches?.length > 0) {
      e = e.changedTouches[0];
    } else if (e.touches?.length > 0) {
      e = e.touches[0];
    }
    const { clientX: x, clientY: y } = e;
    return windowToData(viewportToWindow({ x, y }));
  }
  if (evtToDataRef != null) {
    // share with outside world
    evtToDataRef.current = evtToData;
  }

  function handleClick(e) {
    if (!frame.isFocused) return;
    if (ignoreNextClick.current) {
      ignoreNextClick.current = false;
      return;
    }
    if (selectedTool == "hand") return;
    if (selectedTool == "select") {
      if (e.target == gridDivRef.current) {
        // clear selection
        frame.actions.clearSelection(frame.id);
        const edgeStart = frame.desc.get("edgeStart");
        if (edgeStart) {
          frame.actions.clearEdgeCreateStart(frame.id);
        }
      } else {
        // clicked on an element on the canvas; either stay selected or let
        // it handle selecting itself.
      }
      return;
    }
    const position: Partial<Element> = {
      ...evtToData(e),
      z: transforms.zMax + 1,
    };
    let elt: Partial<Element> = { type: selectedTool as any };

    // TODO -- move some of this to the spec?
    if (selectedTool == "note") {
      elt = getToolElement("note");
    } else if (selectedTool == "timer") {
      elt = getToolElement("timer");
    } else if (selectedTool == "icon") {
      elt = getToolElement("icon");
    } else if (selectedTool == "text") {
      elt = getToolElement("text");
    } else if (selectedTool == "frame") {
      elt = getToolElement("frame");
    } else if (selectedTool == "chat") {
      elt.w = 375;
      elt.h = 450;
    }

    const element = {
      ...position,
      ...elt,
    };

    // create element
    const { id } = frame.actions.createElement(element, true);

    // in some cases, select it
    if (
      selectedTool == "text" ||
      selectedTool == "note" ||
      selectedTool == "code" ||
      selectedTool == "timer" ||
      selectedTool == "chat" ||
      selectedTool == "frame"
    ) {
      frame.actions.setSelectedTool(frame.id, "select");
      frame.actions.setSelection(frame.id, id);
    }
  }

  const saveViewport = isNavigator
    ? () => {}
    : useMemo(() => {
        return throttle(() => {
          const viewport = getViewportData();
          if (viewport) {
            lastViewport.current = viewport;
            frame.actions.saveViewport(frame.id, viewport);
          }
        }, 50);
      }, []);

  const onMouseDown = (e) => {
    if (selectedTool == "hand" || e.button == MIDDLE_MOUSE_BUTTON) {
      const c = canvasRef.current;
      if (c == null) return;
      handRef.current = {
        clientX: e.clientX,
        clientY: e.clientY,
        start: offset.get(),
      };
      return;
    }
    if (selectedTool == "select" || selectedTool == "frame") {
      if (e.target != gridDivRef.current) return;
      // draw a rectangular to select multiple items
      const point = getMousePos(e);
      if (point == null) return;
      mousePath.current = [point];
      return;
    }
    if (selectedTool == "pen") {
      const point = getMousePos(e);
      if (point == null) return;
      mousePath.current = [point];
      ignoreNextClick.current = true;
      return;
    }
  };

  const onTouchStart = (e) => {
    if (!isNavigator && selectedTool == "hand") {
      // touch already does hand by default
      return;
    }
    onMouseDown(e.touches[0]);
    // This is needed for all touch events when drawing, since otherwise the
    // entire page gets selected randomly when doing things.
    if (selectedTool == "pen") {
      e.preventDefault();
    }
  };

  const onMouseUp = (e) => {
    if (handRef.current != null) {
      handRef.current = null;
      return;
    }
    setSelectRect(null);
    if (mousePath.current == null) return;
    try {
      if (selectedTool == "select" || selectedTool == "frame") {
        if (mousePath.current.length < 2) return;
        setSelectRect(null);
        ignoreNextClick.current = true;
        if (e != null && !(e.altKey || e.metaKey || e.ctrlKey || e.shiftKey)) {
          frame.actions.clearSelection(frame.id);
        }
        const p0 = mousePath.current[0];
        const p1 = mousePath.current[1];
        const rect = pointsToRect(
          transforms.windowToDataNoScale(p0.x, p0.y),
          transforms.windowToDataNoScale(p1.x, p1.y)
        );
        if (selectedTool == "frame") {
          // make a frame at the selection.  Note that we put
          // it UNDER everything.
          const elt = getToolElement("frame");
          if (elt.data?.aspectRatio) {
            const ar = aspectRatioToNumber(elt.data.aspectRatio);
            if (ar != 0) {
              rect.h = rect.w / ar;
            }
          }

          const { id } = frame.actions.createElement(
            { ...elt, ...rect, z: transforms.zMin - 1 },
            true
          );
          frame.actions.setSelectedTool(frame.id, "select");
          frame.actions.setSelection(frame.id, id);
        } else {
          // select everything in selection
          const overlapping = getOverlappingElements(elements, rect);
          const ids = overlapping.map((element) => element.id);
          frame.actions.setSelectionMulti(frame.id, ids, "add");
        }
        return;
      } else if (selectedTool == "pen") {
        const canvas = penCanvasRef.current;
        if (canvas != null) {
          const ctx = canvas.getContext("2d");
          if (ctx != null) {
            clearCanvas({ ctx });
          }
        }
        if (mousePath.current == null || mousePath.current.length <= 0) {
          return;
        }
        ignoreNextClick.current = true;
        // Rounding makes things look really bad when zoom is much greater
        // than 100%, so if user is zoomed in doing something precise, we
        // preserve the full points.
        const toData =
          fontSizeToZoom(font_size) < 1
            ? ({ x, y }) => pointRound(transforms.windowToDataNoScale(x, y))
            : ({ x, y }) => transforms.windowToDataNoScale(x, y);

        const { x, y } = toData(mousePath.current[0]);
        let xMin = x,
          xMax = x;
        let yMin = y,
          yMax = y;
        const path: Point[] = [{ x, y }];
        let lastPt = path[0];
        for (const pt of mousePath.current.slice(1)) {
          const thisPt = toData(pt);
          if (pointEqual(lastPt, thisPt)) {
            lastPt = thisPt;
            continue;
          }
          lastPt = thisPt;
          const { x, y } = thisPt;
          path.push({ x, y });
          if (x < xMin) xMin = x;
          if (x > xMax) xMax = x;
          if (y < yMin) yMin = y;
          if (y > yMax) yMax = y;
        }
        for (const pt of path) {
          pt.x = pt.x - xMin;
          pt.y = pt.y - yMin;
        }

        frame.actions.createElement(
          {
            x: xMin,
            y: yMin,
            z: transforms.zMax + 1,
            w: xMax - xMin + 1,
            h: yMax - yMin + 1,
            data: { path: compressPath(path), ...getToolElement("pen").data },
            type: "pen",
          },
          true
        );

        return;
      }
    } finally {
      mousePath.current = null;
    }
  };

  const onTouchEnd = (e) => {
    if (!isNavigator && selectedTool == "hand") return;
    onMouseUp(e);
    if (selectedTool == "pen") {
      e.preventDefault();
    }
  };

  const onTouchCancel = (e) => {
    if (selectedTool == "pen") {
      e.preventDefault();
    }
  };

  // convert from clientX,clientY to unscaled window coordinates,
  function getMousePos(
    e: {
      clientX: number;
      clientY: number;
    } | null
  ): { x: number; y: number } | undefined {
    if (e == null) return;
    const c = canvasRef.current;
    if (c == null) return;
    const rect = c.getBoundingClientRect();
    if (rect == null) return;
    const { x, y } = offset.get();
    return {
      x: (-x + e.clientX - rect.left) / scaleRef.current,
      y: (-y + e.clientY - rect.top) / scaleRef.current,
    };
  }

  const onMouseMove = (e, touch = false) => {
    // this us used for zooming:
    mouseMoveRef.current = e;
    lastMouseRef.current = evtToData(e);

    if (!touch && !e.buttons) {
      // mouse button no longer down - cancel any capture.
      // This can happen with no mouseup, due to mouseup outside
      // of the div, i.e., drag off the edge.
      onMouseUp(e);
      return;
    }
    if (handRef.current != null) {
      // dragging with hand tool
      const c = canvasRef.current;
      if (c == null) return;
      const { clientX, clientY, start } = handRef.current;
      const deltaX = e.clientX - clientX;
      const deltaY = e.clientY - clientY;
      offset.set({ x: start.x + deltaX, y: start.y + deltaY });
      return;
    }
    if (mousePath.current == null) return;
    e.preventDefault?.(); // only makes sense for mouse not touch.
    if (selectedTool == "select" || selectedTool == "frame") {
      const point = getMousePos(e);
      if (point == null) return;
      mousePath.current[1] = point;
      setSelectRect(pointsToRect(mousePath.current[0], mousePath.current[1]));
      return;
    }
    if (selectedTool == "pen") {
      const point = getMousePos(e);
      if (point == null) return;
      mousePath.current.push(point);
      if (mousePath.current.length <= 1) return;
      const canvas = penCanvasRef.current;
      if (canvas == null) return;
      const ctx = canvas.getContext("2d");
      if (ctx == null) return;
      /*
      NOTE/TODO: we are again scaling/redrawing the *entire* curve every time
      we get new mouse move.  Curves are pretty small, and the canvas is limited
      in size, so this is actually working and feels fast on devices I've tried.
      But it would obviously be better to draw only what is new properly.
      That said, do that with CARE because I did have one implementation of that
      and so many lines were drawn on top of each other that highlighting
      didn't look transparent during the preview.

      The second bad thing about this is that the canvas is covering the entire
      current span of all elements.  Thus as that gets large, the resolution of
      the preview goes down further. It would be better to use a canvas that is
      just over the visible viewport.

      So what we have works fine now, but there's a lot of straightforward but
      tedious room for improvement to make the preview look perfect as you draw.
      */
      clearCanvas({ ctx });
      ctx.restore();
      ctx.save();
      ctx.scale(penDPIFactor, penDPIFactor);
      const path: Point[] = [];
      for (const point of mousePath.current) {
        path.push({
          x: point.x * canvasScaleRef.current,
          y: point.y * canvasScaleRef.current,
        });
      }
      const { color, radius, opacity } = getToolElement("pen").data ?? {};
      drawCurve({
        ctx,
        path,
        color,
        radius: canvasScaleRef.current * (radius ?? 1),
        opacity,
      });
      return;
    }
  };

  const onTouchMove = (e) => {
    if (!isNavigator && selectedTool == "hand") return;
    onMouseMove(e.touches[0], true);
    if (selectedTool == "pen") {
      e.preventDefault();
    }
  };

  if (!isNavigator) {
    window.x = {
      scaleDivRef,
      canvasRef,
      offset,
      scale,
      frame,
      saveViewport,
    };
  }

  return (
    <div
      className={"smc-vfill"}
      ref={canvasRef}
      style={{
        ...style,
        touchAction:
          typeof selectedTool == "string" &&
          ["select", "pen", "frame"].includes(selectedTool)
            ? "none"
            : undefined,
        userSelect: "none",
        overflow: "hidden",
        position: "relative",
      }}
      onClick={(evt) => {
        mousePath.current = null;
        if (isNavigator) {
          if (ignoreNextClick.current) {
            ignoreNextClick.current = false;
            return;
          }
          frame.actions.setViewportCenter(frame.id, evtToData(evt));
          return;
        }
        if (!readOnly) {
          handleClick(evt);
        }
      }}
      onScroll={() => {
        saveViewport();
      }}
      onMouseDown={!isNavigator ? onMouseDown : undefined}
      onMouseMove={!isNavigator ? onMouseMove : undefined}
      onMouseUp={!isNavigator ? onMouseUp : undefined}
      onTouchStart={!isNavigator ? onTouchStart : undefined}
      onTouchMove={!isNavigator ? onTouchMove : undefined}
      onTouchEnd={!isNavigator ? onTouchEnd : undefined}
      onTouchCancel={!isNavigator ? onTouchCancel : undefined}
      onCopy={
        !isNavigator
          ? (event: ClipboardEvent<HTMLDivElement>) => {
              event.preventDefault();
              const selectedElements = getSelectedElements({
                elements,
                selection,
              });
              const encoded = encodeForCopy(selectedElements);
              event.clipboardData.setData(
                "application/x-cocalc-whiteboard",
                encoded
              );
            }
          : undefined
      }
      onCut={
        isNavigator || readOnly
          ? undefined
          : (event: ClipboardEvent<HTMLDivElement>) => {
              event.preventDefault();
              const selectedElements = getSelectedElements({
                elements,
                selection,
              });
              const encoded = encodeForCopy(selectedElements);
              event.clipboardData.setData(
                "application/x-cocalc-whiteboard",
                encoded
              );
              frame.actions.deleteElements(selectedElements);
            }
      }
      onPaste={
        isNavigator || readOnly
          ? undefined
          : (event: ClipboardEvent<HTMLDivElement>) => {
              const encoded = event.clipboardData.getData(
                "application/x-cocalc-whiteboard"
              );
              if (encoded) {
                // copy/paste between whiteboards of their own structued data
                const pastedElements = decodeForPaste(encoded);
                /* TODO: should also get where mouse is? */
                let target: Point | undefined = undefined;
                const pos = getMousePos(mousePos.current);
                if (pos != null) {
                  const { x, y } = pos;
                  target = transforms.windowToDataNoScale(x, y);
                } else {
                  const point = getCenterPositionWindow();
                  if (point != null) {
                    target = windowToData(point);
                  }
                }

                const ids = frame.actions.insertElements(
                  pastedElements,
                  target
                );
                frame.actions.setSelectionMulti(frame.id, ids);
              } else {
                // nothing else implemented yet!
              }
            }
      }
    >
      <div
        ref={scaleDivRef}
        style={{
          position: "absolute",
          left: `${offset.get().x}px`,
          top: `${offset.get().y}px`,
          transform: `scale(${canvasScale})`,
          transition: "transform left top 0.1s",
          transformOrigin: "top left",
        }}
      >
        {!isNavigator && selectedTool == "pen" && (
          <canvas
            ref={penCanvasRef}
            width={canvasScaleRef.current * penDPIFactor * transforms.width}
            height={canvasScaleRef.current * penDPIFactor * transforms.height}
            style={{
              width: `${transforms.width}px`,
              height: `${transforms.height}px`,
              cursor: TOOLS[selectedTool]?.cursor,
              position: "absolute",
              zIndex: MAX_ELEMENTS + 1,
              top: 0,
              left: 0,
            }}
          />
        )}
        {selectRect != null && (
          <div
            style={{
              position: "absolute",
              left: `${selectRect.x}px`,
              top: `${selectRect.y}px`,
              width: `${selectRect.w}px`,
              height: `${selectRect.h}px`,
              border: `${
                SELECTED_BORDER_WIDTH / canvasScale
              }px solid ${SELECTED_BORDER_COLOR}`,
              zIndex: MAX_ELEMENTS + 100,
            }}
          >
            <div
              style={{
                width: "100%",
                height: "100%",
                background: "blue",
                opacity: 0.1,
              }}
            ></div>
          </div>
        )}
        <div
          ref={innerCanvasRef}
          style={{
            cursor:
              frame.isFocused && selectedTool
                ? selectedTool == "hand" && handRef.current
                  ? "grabbing"
                  : TOOLS[selectedTool]?.cursor
                : undefined,
            position: "relative",
          }}
        >
          {!isNavigator && <Grid transforms={transforms} divRef={gridDivRef} />}
          {v}
        </div>
      </div>
    </div>
  );
}

function getSelectedElements({
  elements,
  selection,
}: {
  elements: Element[];
  selection?: Set<string>;
}): Element[] {
  if (!selection) return [];
  return elements.filter((element) => selection.has(element.id));
}
