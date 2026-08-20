import { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod/v4";

type ToolInput = Tool["inputSchema"];

// Helper to convert Zod schema to JSON schema using Zod v4's native support
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const toJsonSchema = (schema: z.ZodType<any>): ToolInput => {
  return z.toJSONSchema(schema) as ToolInput;
};

/* Input schemas for the load-test tools */
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

const RenderImageSchema = z.object({});

const OversizedTextSchema = z.object({
  megabytes: z
    .number()
    .min(1)
    .max(8)
    .default(1.5)
    .describe("Approximate size of the returned text, in megabytes"),
});

const AlwaysFailsSchema = z.object({});

const SlowEchoSchema = z.object({
  message: z.string().describe("Message to echo back after the delay"),
});

const CounterSchema = z.object({
  op: z
    .enum(["increment", "read"])
    .describe("Increment the session counter, or read its current value"),
});

enum LoadTestToolName {
  CLASSIFY = "classify",
  RENDER_IMAGE = "render_image",
  OVERSIZED_TEXT = "oversized_text",
  ALWAYS_FAILS = "always_fails",
  SLOW_ECHO = "slow_echo",
  COUNTER = "counter",
}

// Delay of the slow tool, chosen to sit past a typical ten-second client budget
const SLOW_ECHO_DELAY_MS = 12_000;

interface LoadTestTools {
  tools: Tool[];
  /** Returns undefined when the tool name belongs to another handler */
  handleCall: (
    name: string,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    args: Record<string, any> | undefined
  ) => Promise<CallToolResult | undefined>;
}

/**
 * Tools that exercise a governing proxy: diverse argument schemas for
 * argument-level policy, plus image, oversized, failing, slow and stateful
 * returns. One instance is created per MCP server, so counter state is scoped
 * to a single session.
 */
export const createLoadTestTools = (): LoadTestTools => {
  let counter = 0;

  const tools: Tool[] = [
    {
      name: LoadTestToolName.CLASSIFY,
      description:
        "Classifies a subject; exercises enum, bounded number, boolean, array and nested object arguments",
      inputSchema: toJsonSchema(ClassifySchema),
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
  ];

  const handleCall = async (
    name: string,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    args: Record<string, any> | undefined
  ): Promise<CallToolResult | undefined> => {
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

    if (name === LoadTestToolName.RENDER_IMAGE) {
      RenderImageSchema.parse(args);
      return {
        content: [
          {
            type: "image",
            data: CHECKERBOARD_IMAGE,
            mimeType: "image/png",
          },
        ],
      };
    }

    if (name === LoadTestToolName.OVERSIZED_TEXT) {
      const { megabytes } = OversizedTextSchema.parse(args);
      const line = "The quick brown fox jumps over the lazy dog. ";
      const target = Math.ceil(megabytes * 1024 * 1024);
      const text = line.repeat(Math.ceil(target / line.length));
      return {
        content: [{ type: "text", text }],
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
      await new Promise((resolve) => setTimeout(resolve, SLOW_ECHO_DELAY_MS));
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
        counter += 1;
      }
      return {
        content: [{ type: "text", text: `Counter: ${counter}` }],
        structuredContent: { counter },
      };
    }

    return undefined;
  };

  return { tools, handleCall };
};

// A 32x32 checkerboard PNG
const CHECKERBOARD_IMAGE =
  "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAP0lEQVR4nGP4igNo52zAikhVzzBqwagFQ8ACahmES/2oBaMWDAULqGUQzow2asGoBUPAAppntFELRi0Y/BYAALSyTHm1FMxRAAAAAElFTkSuQmCC";
