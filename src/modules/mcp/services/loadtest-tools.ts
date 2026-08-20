/**
 * Load-test tools: one module of tools that exercise a governing proxy in front
 * of this server — argument-level policy, awkward return shapes, deterministic
 * failures, transport-level chaos and per-session state.
 *
 * Everything variable is derived from (session id, invocation cursor) through
 * `seedFor`, so any observed behavior reproduces exactly: no Math.random, and no
 * wall-clock value ever decides what a tool returns. Tools that vary take an
 * optional `cursor` argument that pins the seed to a chosen invocation.
 */

import { NextFunction, Request, Response } from "express";
import zlib from "node:zlib";
import {
  CallToolResult,
  ErrorCode,
  McpError,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod/v4";

type ToolInput = Tool["inputSchema"];

// Helper to convert Zod schema to JSON schema using Zod v4's native support.
// io: "input" matters here: these tools use .default(), and the output view
// advertises defaulted arguments as required, so a validating proxy would
// reject calls this server accepts.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const toJsonSchema = (schema: z.ZodType<any>): ToolInput => {
  return z.toJSONSchema(schema, { io: "input" }) as ToolInput;
};

/* ------------------------------------------------------------------ *
 * Deterministic core
 * ------------------------------------------------------------------ */

/** FNV-1a, 32 bit */
const fnv1a = (input: string): number => {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
};

/** The one seed source: (session id, invocation cursor) */
const seedFor = (sessionId: string, cursor: number): number =>
  fnv1a(`${sessionId}:${cursor}`);

/** xorshift32, seeded; returns bytes and floats reproducibly */
const makeRandom = (seed: number) => {
  let state = seed >>> 0 || 0x9e3779b9;
  return () => {
    state ^= state << 13;
    state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5;
    state >>>= 0;
    return state;
  };
};

/* ------------------------------------------------------------------ *
 * Per-session state
 * ------------------------------------------------------------------ */

interface SessionState {
  /** Number of load-test tool invocations seen in this session */
  invocations: number;
  counter: number;
  vanished: boolean;
  /** Version of the schema last served for the mutating-schema tool */
  mutatingSchemaVersion: number;
}

const sessionStates = new Map<string, SessionState>();

const stateFor = (sessionId: string): SessionState => {
  let state = sessionStates.get(sessionId);
  if (!state) {
    state = {
      invocations: 0,
      counter: 0,
      vanished: false,
      mutatingSchemaVersion: 1,
    };
    sessionStates.set(sessionId, state);
  }
  return state;
};

/* ------------------------------------------------------------------ *
 * Generators
 * ------------------------------------------------------------------ */

const WORDS = [
  "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
  "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
];

/** Deterministic filler text of exactly `bytes` characters */
const generateText = (seed: number, bytes: number): string => {
  const next = makeRandom(seed);
  const block: string[] = [];
  let blockLength = 0;
  while (blockLength < 4096) {
    const word = WORDS[next() % WORDS.length];
    block.push(word);
    blockLength += word.length + 1;
  }
  const chunk = `${block.join(" ")}\n`;
  return chunk.repeat(Math.ceil(bytes / chunk.length)).slice(0, bytes);
};

const crc32 = (buffer: Buffer): number => {
  let crc = 0xffffffff;
  for (let i = 0; i < buffer.length; i++) {
    let c = (crc ^ buffer[i]) & 0xff;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    crc = c ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
};

const pngChunk = (type: string, data: Buffer): Buffer => {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const typed = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(typed));
  return Buffer.concat([length, typed, checksum]);
};

/** Deterministic RGB-noise PNG of `side` x `side` pixels, base64 encoded */
const generatePng = (seed: number, side: number): string => {
  const next = makeRandom(seed);
  const raw = Buffer.alloc((side * 3 + 1) * side);
  let offset = 0;
  for (let y = 0; y < side; y++) {
    raw[offset++] = 0; // no per-scanline filter
    for (let x = 0; x < side; x++) {
      const value = next();
      raw[offset++] = value & 0xff;
      raw[offset++] = (value >>> 8) & 0xff;
      raw[offset++] = (value >>> 16) & 0xff;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(side, 0);
  header.writeUInt32BE(side, 4);
  header[8] = 8; // bit depth
  header[9] = 2; // colour type: truecolour
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", zlib.deflateSync(raw, { level: 1 })),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
  return png.toString("base64");
};

/** Strings chosen to be hostile to naive JSON, logging and terminal handling */
const HOSTILE_STRINGS: Record<string, string> = {
  emoji: "🙈🙉🙊 family: 👨‍👩‍👧‍👦 flag: 🇯🇵",
  rtl: "before ‮reversed‬ after — عربى עברית",
  control: "bell:\u0007 null:\u0000 backspace:\u0008 vertical-tab:\u000b",
  quotes: "she said \"hi\" and 'bye' and `tick` and \\backslash\\",
  json_bait: '{"not":"really json","closing":"}"} </script>',
  lone_surrogate_escaped: "literal escape, not a real surrogate: \\ud800\\udfff",
  combining: "ź́́́́ à́̂̃",
  wide: "全角文字とｈａｌｆｗｉｄｔｈ и кириллица",
  whitespace: "tab:\t newline:\n crlf:\r\n nbsp:  zwsp:​",
};

/** Nested object, `depth` levels deep, deterministic in `seed` */
const nestedValue = (
  seed: number,
  depth: number
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
): Record<string, any> => {
  const next = makeRandom(seed);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let node: Record<string, any> = { depth: 0, leaf: true, label: WORDS[next() % WORDS.length] };
  for (let level = 1; level <= depth; level++) {
    node = {
      depth: level,
      leaf: false,
      label: WORDS[next() % WORDS.length],
      child: node,
    };
  }
  return node;
};

/* ------------------------------------------------------------------ *
 * Input schemas
 * ------------------------------------------------------------------ */

const CursorSchema = z
  .int()
  .min(0)
  .optional()
  .describe(
    "Pin the seed to this invocation cursor instead of the session's own counter; makes a call reproducible"
  );

const ClassifySchema = z.object({
  category: z
    .enum(["billing", "security", "onboarding", "support", "other"])
    .describe("Category to classify the subject under"),
  confidence: z
    .number()
    .min(0)
    .max(1)
    .describe("Confidence in the classification, between 0 and 1"),
  urgent: z.boolean().describe("Whether the classification is urgent"),
  tags: z.array(z.string()).describe("Free-form tags attached to the subject"),
  subject: z
    .object({
      name: z.string().describe("Name of the subject being classified"),
      region: z
        .enum(["us", "eu", "apac"])
        .optional()
        .describe("Region the subject belongs to"),
      priority: z
        .int()
        .min(1)
        .max(5)
        .optional()
        .describe("Priority of the subject, 1 (highest) to 5 (lowest)"),
    })
    .describe("The subject of the classification"),
});

const PingSchema = z.object({});

const TEXT_SIZES: Record<string, number> = {
  "1kb": 1024,
  "100kb": 100 * 1024,
  "1mb": 1024 * 1024,
  "4mb": 4 * 1024 * 1024,
};

const LATENCIES: Record<string, number> = {
  "0ms": 0,
  "50ms": 50,
  "1s": 1_000,
  "10s": 10_000,
  near_timeout: 55_000,
};

const LatencySchema = z
  .enum(["0ms", "50ms", "1s", "10s", "near_timeout"])
  .default("0ms")
  .describe("Latency bucket to sleep for before returning");

const ChaosTextSchema = z.object({
  size: z
    .enum(["1kb", "100kb", "1mb", "4mb"])
    .default("1kb")
    .describe("Approximate size of the returned text"),
  latency: LatencySchema,
  cursor: CursorSchema,
});

const IMAGE_SIDES: Record<string, number> = {
  tiny: 32,
  small: 128,
  large: 512,
  huge: 1024,
};

const ChaosImageSchema = z.object({
  size: z
    .enum(["tiny", "small", "large", "huge"])
    .default("tiny")
    .describe("Pixel dimensions of the generated PNG; huge is deliberately obnoxious"),
  with_text: z
    .boolean()
    .default(false)
    .describe("Return a text block alongside the image"),
  cursor: CursorSchema,
});

const ChaosResultSchema = z.object({
  shape: z
    .enum(["empty", "unicode", "nested"])
    .default("empty")
    .describe("Result shape: no content, hostile Unicode strings, or a nested structure"),
  depth: z
    .int()
    .min(0)
    .max(32)
    .default(4)
    .describe("Nesting depth of the returned structure when shape is nested"),
  cursor: CursorSchema,
});

const ChaosFailSchema = z.object({
  mode: z
    .enum(["tool_error", "client_error", "server_error", "intermittent"])
    .default("tool_error")
    .describe(
      "tool_error: isError result; client_error: 400-shaped JSON-RPC InvalidParams; server_error: 500-shaped InternalError; intermittent: server_error every Nth invocation"
    ),
  every_n: z
    .int()
    .min(1)
    .default(17)
    .describe("Intermittent mode fails when the invocation cursor is a multiple of this"),
  cursor: CursorSchema,
});

const DeepNestSchema = z.object({
  depth: z
    .int()
    .min(0)
    .max(32)
    .default(8)
    .describe("Depth of the returned structure"),
  payload: z
    .object({
      level1: z
        .object({
          level2: z
            .object({
              level3: z
                .object({
                  level4: z
                    .object({
                      value: z.string().describe("Leaf value"),
                      flag: z.boolean().optional().describe("Leaf flag"),
                    })
                    .describe("Fourth level"),
                })
                .describe("Third level"),
            })
            .describe("Second level"),
        })
        .describe("First level"),
    })
    .optional()
    .describe("Deeply nested argument, echoed back"),
  cursor: CursorSchema,
});

const SlowEchoSchema = z.object({
  message: z.string().describe("Message to echo back after the delay"),
});

const OversizedTextSchema = z.object({
  megabytes: z
    .number()
    .min(1)
    .max(8)
    .default(1.5)
    .describe("Approximate size of the returned text, in megabytes"),
  cursor: CursorSchema,
});

const RenderImageSchema = z.object({});
const AlwaysFailsSchema = z.object({});

const CounterSchema = z.object({
  op: z
    .enum(["increment", "read"])
    .describe("Increment the session counter, or read its current value"),
});

const DeterministicSampleSchema = z.object({
  cursor: CursorSchema,
});

const VanishingSchema = z.object({});

const UnauthorizedSchema = z.object({
  mode: z
    .enum(["always", "every_n"])
    .default("always")
    .describe("Return 401 on every call, or on every Nth invocation"),
  every_n: z
    .int()
    .min(1)
    .default(17)
    .describe("Invocation multiple that gets the 401 when mode is every_n"),
});

const CloseConnectionSchema = z.object({
  bytes_first: z
    .int()
    .min(0)
    .max(4096)
    .default(64)
    .describe("Bytes of body to write before destroying the socket"),
});

/** Two incompatible versions of the same tool's schema */
const MUTATING_SCHEMAS: ToolInput[] = [
  toJsonSchema(
    z.object({
      value: z.string().describe("Schema version 1 wants a string here"),
    })
  ),
  toJsonSchema(
    z.object({
      value: z.number().describe("Schema version 2 wants a number here"),
      mode: z
        .enum(["strict", "lax"])
        .describe("Schema version 2 requires this too"),
    })
  ),
];

const ENORMOUS_SCHEMA_FIELDS = 250;

const enormousSchema = (): ToolInput => {
  const shape: Record<string, z.ZodType> = {};
  for (let i = 0; i < ENORMOUS_SCHEMA_FIELDS; i++) {
    const key = `field_${String(i).padStart(3, "0")}`;
    if (i % 4 === 0) {
      shape[key] = z
        .string()
        .optional()
        .describe(`Optional string field ${i} of the enormous schema`);
    } else if (i % 4 === 1) {
      shape[key] = z
        .number()
        .min(0)
        .max(1000)
        .optional()
        .describe(`Optional bounded number field ${i} of the enormous schema`);
    } else if (i % 4 === 2) {
      shape[key] = z
        .enum(["one", "two", "three", "four"])
        .optional()
        .describe(`Optional enum field ${i} of the enormous schema`);
    } else {
      shape[key] = z
        .array(z.string())
        .optional()
        .describe(`Optional array field ${i} of the enormous schema`);
    }
  }
  return toJsonSchema(z.object(shape));
};

/** Filler tools, so tools/list is large */
const BULK_TOOL_COUNT = 40;
const bulkToolName = (index: number) => `bulk_op_${String(index).padStart(2, "0")}`;

const bulkSchema = (index: number): ToolInput =>
  toJsonSchema(
    z.object({
      subject: z.string().describe(`Subject for bulk operation ${index}`),
      amount: z
        .number()
        .min(0)
        .max(1000)
        .optional()
        .describe(`Bounded amount for bulk operation ${index}`),
      mode: z
        .enum(["read", "write", "audit"])
        .optional()
        .describe(`Mode for bulk operation ${index}`),
    })
  );

enum LoadTestToolName {
  PING = "ping",
  CLASSIFY = "classify",
  CHAOS_TEXT = "chaos_text",
  CHAOS_IMAGE = "chaos_image",
  CHAOS_RESULT = "chaos_result",
  CHAOS_FAIL = "chaos_fail",
  DEEP_NEST = "deep_nest",
  RENDER_IMAGE = "render_image",
  OVERSIZED_TEXT = "oversized_text",
  ALWAYS_FAILS = "always_fails",
  SLOW_ECHO = "slow_echo",
  COUNTER = "counter",
  DETERMINISTIC_SAMPLE = "deterministic_sample",
  ENORMOUS_SCHEMA = "enormous_schema",
  VANISHING = "vanishing",
  MUTATING_SCHEMA = "mutating_schema",
  UNAUTHORIZED = "unauthorized",
  CLOSE_CONNECTION = "close_connection",
}

/** Transport-level tools, intercepted before the MCP server sees them */
const TRANSPORT_CHAOS_TOOLS: string[] = [
  LoadTestToolName.UNAUTHORIZED,
  LoadTestToolName.CLOSE_CONNECTION,
];

const SLOW_ECHO_DELAY_MS = 12_000;

const sleep = (ms: number) =>
  new Promise((resolve) => setTimeout(resolve, ms));

interface LoadTestTools {
  /** Recomputed per request: two tools change or disappear as the session runs */
  listTools: () => Tool[];
  /** Returns undefined when the tool name belongs to another handler */
  handleCall: (
    name: string,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    args: Record<string, any> | undefined
  ) => Promise<CallToolResult | undefined>;
  dispose: () => void;
}

/**
 * One instance per MCP server. State is keyed by session id, so it survives for
 * the life of the session and is shared with nothing else.
 */
export const createLoadTestTools = (sessionId: string): LoadTestTools => {
  const listTools = (): Tool[] => {
    const state = stateFor(sessionId);

    const tools: Tool[] = [
      {
        name: LoadTestToolName.PING,
        description: "Tiny, fast, always succeeds",
        inputSchema: toJsonSchema(PingSchema),
      },
      {
        name: LoadTestToolName.CLASSIFY,
        description:
          "Classifies a subject; exercises enum, bounded number, boolean, array and nested object arguments",
        inputSchema: toJsonSchema(ClassifySchema),
      },
      {
        name: LoadTestToolName.CHAOS_TEXT,
        description:
          "Returns deterministic text of a chosen size after a chosen latency bucket",
        inputSchema: toJsonSchema(ChaosTextSchema),
      },
      {
        name: LoadTestToolName.CHAOS_IMAGE,
        description:
          "Returns a deterministic PNG of a chosen size, optionally mixed with text",
        inputSchema: toJsonSchema(ChaosImageSchema),
      },
      {
        name: LoadTestToolName.CHAOS_RESULT,
        description:
          "Returns an empty result, hostile Unicode strings, or a deeply nested structure",
        inputSchema: toJsonSchema(ChaosResultSchema),
      },
      {
        name: LoadTestToolName.CHAOS_FAIL,
        description:
          "Fails deterministically: tool error, 400-shaped, 500-shaped, or every Nth invocation",
        inputSchema: toJsonSchema(ChaosFailSchema),
      },
      {
        name: LoadTestToolName.DEEP_NEST,
        description: "Echoes a deeply nested argument and returns a nested result",
        inputSchema: toJsonSchema(DeepNestSchema),
      },
      {
        name: LoadTestToolName.RENDER_IMAGE,
        description: "Returns a small PNG as an image content block",
        inputSchema: toJsonSchema(RenderImageSchema),
      },
      {
        name: LoadTestToolName.OVERSIZED_TEXT,
        description: "Returns more than a megabyte of generated text",
        inputSchema: toJsonSchema(OversizedTextSchema),
      },
      {
        name: LoadTestToolName.ALWAYS_FAILS,
        description: "Always returns a tool error result",
        inputSchema: toJsonSchema(AlwaysFailsSchema),
      },
      {
        name: LoadTestToolName.SLOW_ECHO,
        description: `Echoes its message after sleeping ${
          SLOW_ECHO_DELAY_MS / 1000
        } seconds`,
        inputSchema: toJsonSchema(SlowEchoSchema),
      },
      {
        name: LoadTestToolName.COUNTER,
        description:
          "Session-scoped counter; increments persist across calls within one session",
        inputSchema: toJsonSchema(CounterSchema),
      },
      {
        name: LoadTestToolName.DETERMINISTIC_SAMPLE,
        description:
          "Reports the seed and derived sample for a given (session, cursor); same inputs, same output",
        inputSchema: toJsonSchema(DeterministicSampleSchema),
      },
      {
        name: LoadTestToolName.ENORMOUS_SCHEMA,
        description: `Accepts ${ENORMOUS_SCHEMA_FIELDS} optional fields; echoes which ones were provided`,
        inputSchema: enormousSchema(),
      },
      {
        name: LoadTestToolName.MUTATING_SCHEMA,
        description:
          "Its schema changes between listings; the handler validates the current version, so a listed-then-called client sees a mismatch",
        inputSchema:
          MUTATING_SCHEMAS[(state.mutatingSchemaVersion - 1) % MUTATING_SCHEMAS.length],
      },
      {
        name: LoadTestToolName.UNAUTHORIZED,
        description:
          "Answered by transport-level middleware with HTTP 401, after authentication succeeded",
        inputSchema: toJsonSchema(UnauthorizedSchema),
      },
      {
        name: LoadTestToolName.CLOSE_CONNECTION,
        description:
          "Answered by transport-level middleware, which destroys the socket mid-response",
        inputSchema: toJsonSchema(CloseConnectionSchema),
      },
    ];

    if (!state.vanished) {
      tools.push({
        name: LoadTestToolName.VANISHING,
        description:
          "Disappears from tools/list after its first call in this session",
        inputSchema: toJsonSchema(VanishingSchema),
      });
    }

    for (let i = 0; i < BULK_TOOL_COUNT; i++) {
      tools.push({
        name: bulkToolName(i),
        description: `Filler tool ${i}, present to make tools/list large`,
        inputSchema: bulkSchema(i),
      });
    }

    // Serving the listing advances the mutating tool's schema version
    state.mutatingSchemaVersion += 1;

    return tools;
  };

  const knownToolNames = new Set<string>([
    ...Object.values(LoadTestToolName),
    ...Array.from({ length: BULK_TOOL_COUNT }, (_unused, i) => bulkToolName(i)),
  ]);

  const handleCall = async (
    name: string,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    args: Record<string, any> | undefined
  ): Promise<CallToolResult | undefined> => {
    if (!knownToolNames.has(name)) {
      return undefined;
    }

    const state = stateFor(sessionId);
    const invocation = ++state.invocations;
    // Tools take an optional cursor so a caller can pin the seed
    const cursor =
      typeof args?.cursor === "number" ? (args.cursor as number) : invocation;
    const seed = seedFor(sessionId, cursor);

    if (name === LoadTestToolName.PING) {
      PingSchema.parse(args);
      return { content: [{ type: "text", text: "pong" }] };
    }

    if (name === LoadTestToolName.CLASSIFY) {
      const { category, confidence, urgent, tags, subject } =
        ClassifySchema.parse(args);
      const region = subject.region ?? "unspecified";
      const priority = subject.priority ?? "unspecified";
      return {
        content: [
          {
            type: "text",
            text: `Classified ${subject.name} as ${category} (confidence ${confidence}, urgent ${urgent}, tags [${tags.join(
              ", "
            )}], region ${region}, priority ${priority}).`,
          },
        ],
      };
    }

    if (name === LoadTestToolName.CHAOS_TEXT) {
      const { size, latency } = ChaosTextSchema.parse(args);
      await sleep(LATENCIES[latency]);
      return {
        content: [{ type: "text", text: generateText(seed, TEXT_SIZES[size]) }],
        structuredContent: { cursor, seed, size, latency },
      };
    }

    if (name === LoadTestToolName.CHAOS_IMAGE) {
      const { size, with_text: withText } = ChaosImageSchema.parse(args);
      const data = generatePng(seed, IMAGE_SIDES[size]);
      const content: CallToolResult["content"] = [];
      if (withText) {
        content.push({
          type: "text",
          text: `A ${IMAGE_SIDES[size]}x${IMAGE_SIDES[size]} PNG generated from seed ${seed}:`,
        });
      }
      content.push({ type: "image", data, mimeType: "image/png" });
      return { content, structuredContent: { cursor, seed, size } };
    }

    if (name === LoadTestToolName.CHAOS_RESULT) {
      const { shape, depth } = ChaosResultSchema.parse(args);
      if (shape === "empty") {
        return { content: [] };
      }
      if (shape === "unicode") {
        return {
          content: Object.entries(HOSTILE_STRINGS).map(([key, value]) => ({
            type: "text" as const,
            text: `${key}: ${value}`,
          })),
          structuredContent: { cursor, strings: HOSTILE_STRINGS },
        };
      }
      const nested = nestedValue(seed, depth);
      return {
        content: [{ type: "text", text: JSON.stringify(nested) }],
        structuredContent: { cursor, seed, depth, nested },
      };
    }

    if (name === LoadTestToolName.CHAOS_FAIL) {
      const { mode, every_n: everyN } = ChaosFailSchema.parse(args);
      if (mode === "client_error") {
        throw new McpError(
          ErrorCode.InvalidParams,
          `chaos_fail: 400-shaped failure at cursor ${cursor}`
        );
      }
      if (mode === "server_error") {
        throw new McpError(
          ErrorCode.InternalError,
          `chaos_fail: 500-shaped failure at cursor ${cursor}`
        );
      }
      if (mode === "intermittent") {
        if (cursor % everyN === 0) {
          throw new McpError(
            ErrorCode.InternalError,
            `chaos_fail: intermittent failure at cursor ${cursor} (every ${everyN})`
          );
        }
        return {
          content: [
            {
              type: "text",
              text: `chaos_fail: cursor ${cursor} is not a multiple of ${everyN}, so this call succeeds.`,
            },
          ],
          structuredContent: { cursor, every_n: everyN, failed: false },
        };
      }
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: `chaos_fail: tool error result at cursor ${cursor}.`,
          },
        ],
      };
    }

    if (name === LoadTestToolName.DEEP_NEST) {
      const { depth, payload } = DeepNestSchema.parse(args);
      const nested = nestedValue(seed, depth);
      return {
        content: [
          {
            type: "text",
            text: `Nested result ${depth} levels deep; argument payload ${
              payload ? "echoed" : "absent"
            }.`,
          },
        ],
        structuredContent: { cursor, seed, depth, nested, payload },
      };
    }

    if (name === LoadTestToolName.RENDER_IMAGE) {
      RenderImageSchema.parse(args);
      return {
        content: [
          {
            type: "image",
            data: generatePng(seed, IMAGE_SIDES.tiny),
            mimeType: "image/png",
          },
        ],
      };
    }

    if (name === LoadTestToolName.OVERSIZED_TEXT) {
      const { megabytes } = OversizedTextSchema.parse(args);
      return {
        content: [
          {
            type: "text",
            text: generateText(seed, Math.ceil(megabytes * 1024 * 1024)),
          },
        ],
      };
    }

    if (name === LoadTestToolName.ALWAYS_FAILS) {
      AlwaysFailsSchema.parse(args);
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: "always_fails: this tool always returns an error result.",
          },
        ],
      };
    }

    if (name === LoadTestToolName.SLOW_ECHO) {
      const { message } = SlowEchoSchema.parse(args);
      await sleep(SLOW_ECHO_DELAY_MS);
      return {
        content: [
          {
            type: "text",
            text: `Slow echo after ${SLOW_ECHO_DELAY_MS / 1000}s: ${message}`,
          },
        ],
      };
    }

    if (name === LoadTestToolName.COUNTER) {
      const { op } = CounterSchema.parse(args);
      if (op === "increment") {
        state.counter += 1;
      }
      return {
        content: [{ type: "text", text: `Counter: ${state.counter}` }],
        structuredContent: { counter: state.counter },
      };
    }

    if (name === LoadTestToolName.DETERMINISTIC_SAMPLE) {
      DeterministicSampleSchema.parse(args);
      const next = makeRandom(seed);
      const samples = [next(), next(), next(), next()];
      return {
        content: [
          {
            type: "text",
            text: `seed=${seed} cursor=${cursor} samples=${samples.join(",")}`,
          },
        ],
        structuredContent: {
          session_id: sessionId,
          cursor,
          invocation,
          seed,
          samples,
          word: WORDS[samples[0] % WORDS.length],
        },
      };
    }

    if (name === LoadTestToolName.ENORMOUS_SCHEMA) {
      const provided = Object.keys(args ?? {}).filter((key) => key !== "cursor");
      return {
        content: [
          {
            type: "text",
            text: `Enormous schema declares ${ENORMOUS_SCHEMA_FIELDS} fields; received ${provided.length}: ${provided
              .slice(0, 10)
              .join(", ")}`,
          },
        ],
        structuredContent: {
          declared: ENORMOUS_SCHEMA_FIELDS,
          provided,
        },
      };
    }

    if (name === LoadTestToolName.VANISHING) {
      VanishingSchema.parse(args);
      const first = !state.vanished;
      state.vanished = true;
      return {
        content: [
          {
            type: "text",
            text: first
              ? "vanishing: first call in this session; the tool is now gone from tools/list."
              : "vanishing: already gone from tools/list, but still callable by name.",
          },
        ],
        structuredContent: { first_call: first },
      };
    }

    if (name === LoadTestToolName.MUTATING_SCHEMA) {
      const version =
        ((state.mutatingSchemaVersion - 1) % MUTATING_SCHEMAS.length) + 1;
      const validator =
        version === 1
          ? z.object({ value: z.string() })
          : z.object({
              value: z.number(),
              mode: z.enum(["strict", "lax"]),
            });
      const parsed = validator.safeParse(args);
      if (!parsed.success) {
        throw new McpError(
          ErrorCode.InvalidParams,
          `mutating_schema: arguments do not match schema version ${version} (the listing you read may have shown another version): ${parsed.error.issues
            .map((issue) => `${issue.path.join(".") || "(root)"} ${issue.message}`)
            .join("; ")}`
        );
      }
      return {
        content: [
          {
            type: "text",
            text: `mutating_schema: validated against schema version ${version}.`,
          },
        ],
        structuredContent: { version },
      };
    }

    if (TRANSPORT_CHAOS_TOOLS.includes(name)) {
      // Only reachable when the transport middleware is not in the path, e.g.
      // the legacy SSE endpoint.
      return {
        content: [
          {
            type: "text",
            text: `${name} is answered by the load-test transport middleware on POST /mcp; this request did not pass through it.`,
          },
        ],
      };
    }

    // Bulk filler tools
    const bulkArgs = z
      .object({
        subject: z.string(),
        amount: z.number().min(0).max(1000).optional(),
        mode: z.enum(["read", "write", "audit"]).optional(),
      })
      .parse(args);
    return {
      content: [
        {
          type: "text",
          text: `${name}: ${bulkArgs.mode ?? "read"} ${bulkArgs.subject}${
            bulkArgs.amount === undefined ? "" : ` (${bulkArgs.amount})`
          }`,
        },
      ],
    };
  };

  const dispose = () => {
    sessionStates.delete(sessionId);
  };

  return { listTools, handleCall, dispose };
};

/* ------------------------------------------------------------------ *
 * Transport-level chaos
 * ------------------------------------------------------------------ */

/**
 * Answers the two tools that cannot be expressed as a tool result: a 401 issued
 * after authentication already succeeded, and a connection destroyed mid-
 * response. Every other request is passed straight through.
 */
export const loadTestTransportChaos = (
  req: Request,
  res: Response,
  next: NextFunction
): void => {
  const body = req.body;
  if (
    !body ||
    body.method !== "tools/call" ||
    !TRANSPORT_CHAOS_TOOLS.includes(body.params?.name)
  ) {
    next();
    return;
  }

  // Sessionless requests (no Mcp-Session-Id) share one bucket; the streamable
  // HTTP transport only allows that before initialize, which carries no
  // tools/call, so a real session never lands here.
  const sessionId = (req.headers["mcp-session-id"] as string) ?? "no-session";
  const state = stateFor(sessionId);
  // Peek at the invocation this call would be. Only the path that ANSWERS the
  // request commits it: when we fall through, handleCall does the increment,
  // so an invocation is counted exactly once either way.
  const invocation = state.invocations + 1;
  const toolName = body.params.name as string;
  const args = (body.params.arguments ?? {}) as Record<string, unknown>;

  if (toolName === LoadTestToolName.UNAUTHORIZED) {
    const mode = args.mode === "every_n" ? "every_n" : "always";
    const everyN =
      typeof args.every_n === "number" &&
      Number.isInteger(args.every_n) &&
      args.every_n >= 1
        ? args.every_n
        : 17;
    if (mode === "every_n" && invocation % everyN !== 0) {
      next();
      return;
    }
    state.invocations = invocation;
    res
      .status(401)
      .setHeader("WWW-Authenticate", 'Bearer error="invalid_token"');
    res.json({
      jsonrpc: "2.0",
      id: body.id ?? null,
      error: {
        code: -32001,
        message: `unauthorized: synthetic 401 at invocation ${invocation}`,
      },
    });
    return;
  }

  // close_connection: headers, a partial body, then destroy the socket. The
  // destroy has to wait for the write callback, or the buffered bytes are
  // discarded and the client sees no body at all.
  state.invocations = invocation;
  const bytesFirst =
    typeof args.bytes_first === "number" && Number.isFinite(args.bytes_first)
      ? Math.min(Math.max(Math.trunc(args.bytes_first), 0), 4096)
      : 64;
  res.status(200);
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-store");
  res.flushHeaders();
  res.write(`event: message\ndata: ${"x".repeat(bytesFirst)}\n`, () => {
    req.socket.destroy();
  });
};
