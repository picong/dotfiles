/**
 * Image Auto-Compact Extension
 * (图片自动压缩扩展)
 *
 * Automatically triggers compaction after images are processed by the LLM,
 * replacing image data with text descriptions to reduce token consumption.
 * (在 LLM 处理完图片后自动触发压缩，将图片数据替换为文字描述以减少 token 消耗)
 *
 * Mechanism (机制):
 * 1. Detects when user sends images via `before_agent_start`
 *    (通过 before_agent_start 检测用户是否发送了图片)
 * 2. After the LLM responds (turn_end), triggers compaction if images were detected
 *    (LLM 回复后，如果检测到图片则触发压缩)
 * 3. Custom compaction ensures image content is summarized as text
 *    (自定义压缩确保图片内容被总结为文字)
 */

import { complete } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { convertToLlm, serializeConversation } from "@earendil-works/pi-coding-agent";

// Minimum token threshold to trigger image compaction
// (触发图片压缩的最小 token 阈值)
const IMAGE_COMPACT_MIN_TOKENS = 30_000;

// Delay after turn_end before triggering compaction (ms)
// (turn_end 后触发压缩的延迟时间)
const COMPACT_DELAY_MS = 1500;

export default function (pi: ExtensionAPI) {
	// Track whether current turn has images
	// (跟踪当前轮次是否包含图片)
	let pendingImageCompaction = false;
	let imageCount = 0;
	let compactionInProgress = false;

	// Detect images in user input
	// (检测用户输入中的图片)
	pi.on("before_agent_start", async (event, _ctx) => {
		const images = event.images;
		if (images && images.length > 0) {
			pendingImageCompaction = true;
			imageCount = images.length;
		}
	});

	// After LLM responds, trigger compaction if images were present
	// (LLM 回复后，如果存在图片则触发压缩)
	pi.on("turn_end", async (_event, ctx) => {
		if (!pendingImageCompaction || compactionInProgress) {
			return;
		}

		// Check current token usage
		// (检查当前 token 使用量)
		const usage = ctx.getContextUsage();
		if (!usage || usage.tokens < IMAGE_COMPACT_MIN_TOKENS) {
			// Token usage too low, skip compaction
			// (Token 使用量过低，跳过压缩)
			pendingImageCompaction = false;
			imageCount = 0;
			return;
		}

		// Reset state before triggering
		// (触发前重置状态)
		const currentImageCount = imageCount;
		pendingImageCompaction = false;
		imageCount = 0;
		compactionInProgress = true;

		// Delay slightly to ensure session state is stable
		// (稍微延迟以确保会话状态稳定)
		setTimeout(() => {
			ctx.compact({
				customInstructions: `The conversation contains ${currentImageCount} image(s) that have already been analyzed. Replace image data with text descriptions of what was shown and discussed. Preserve all analysis results and conclusions about the images.`,
				onComplete: () => {
					compactionInProgress = false;
					if (ctx.hasUI) {
						ctx.ui.notify(
							`Image compaction complete: ${currentImageCount} image(s) replaced with text summaries`,
							"info",
						);
					}
				},
				onError: (error) => {
					compactionInProgress = false;
					if (ctx.hasUI) {
						ctx.ui.notify(`Image compaction failed: ${error.message}`, "error");
					}
				},
			});
		}, COMPACT_DELAY_MS);
	});

	// Custom compaction handler - ensures images are properly described
	// (自定义压缩处理器 - 确保图片被正确描述)
	pi.on("session_before_compact", async (event, ctx) => {
		const { preparation, signal } = event;
		const { messagesToSummarize, turnPrefixMessages, tokensBefore, firstKeptEntryId, previousSummary } = preparation;

		// Check if messages contain image content
		// (检查消息中是否包含图片内容)
		const allMessages = [...messagesToSummarize, ...turnPrefixMessages];
		let hasImages = false;

		for (const msg of allMessages) {
			if (msg.role === "user" && Array.isArray(msg.content)) {
				for (const block of msg.content) {
					if (block.type === "image") {
						hasImages = true;
						break;
					}
				}
			}
			if (hasImages) break;
		}

		// Only use custom compaction if images are present
		// (仅在存在图片时使用自定义压缩)
		if (!hasImages) {
			return;
		}

		// Find a model for summarization (prioritize Sonnet, fallback to Haiku)
		// (查找用于总结的模型，优先 Sonnet，回退到 Haiku)
		const model =
			ctx.modelRegistry.find("anthropic", "claude-sonnet-4-20250514") ||
			ctx.modelRegistry.find("anthropic", "claude-haiku-4-20250514");

		if (!model) {
			// Fall back to default compaction
			// (回退到默认压缩)
			return;
		}

		// Resolve auth for the model
		// (解析模型的认证信息)
		const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
		if (!auth.ok || !auth.apiKey) {
			return;
		}

		// Serialize conversation, images will be described as [image] placeholders
		// (序列化对话，图片将被描述为 [image] 占位符)
		const conversationText = serializeConversation(convertToLlm(allMessages));

		// Build previous context
		// (构建之前的上下文)
		const previousContext = previousSummary
			? `\n\nPrevious session summary:\n${previousSummary}`
			: "";

		// Count images in messages for the prompt
		// (统计消息中的图片数量用于提示)
		let totalImages = 0;
		for (const msg of allMessages) {
			if (msg.role === "user" && Array.isArray(msg.content)) {
				for (const block of msg.content) {
					if (block.type === "image") {
						totalImages++;
					}
				}
			}
		}

		const summaryMessages = [
			{
				role: "user" as const,
				content: [
					{
						type: "text" as const,
						text: `You are a conversation summarizer. This conversation contains ${totalImages} image(s) that were sent by the user and analyzed by the assistant.${previousContext}

CRITICAL: The images have already been processed. Your summary MUST include detailed text descriptions of what was in each image and what the assistant said about them. The original image data will be discarded after this summary.

Create a comprehensive summary that captures:
1. Detailed descriptions of each image (what it showed, any text/code/diagrams in it)
2. The assistant's analysis and conclusions about each image
3. Key decisions made and their rationale
4. Important code changes, file modifications, or technical details
5. Current state of any ongoing work
6. Any blockers, issues, or open questions
7. Next steps that were planned or suggested

Format as structured markdown. Be thorough about image descriptions since the originals will be removed.

<conversation>
${conversationText}
</conversation>`,
					},
				],
				timestamp: Date.now(),
			},
		];

		try {
			const response = await complete(
				model,
				{ messages: summaryMessages },
				{
					apiKey: auth.apiKey,
					headers: auth.headers,
					maxTokens: 8192,
					signal,
				},
			);

			const summary = response.content
				.filter((c): c is { type: "text"; text: string } => c.type === "text")
				.map((c) => c.text)
				.join("\n");

			if (!summary.trim()) {
				if (!signal.aborted && ctx.hasUI) {
					ctx.ui.notify("Image compaction summary was empty, using default", "warning");
				}
				return;
			}

			return {
				compaction: {
					summary,
					firstKeptEntryId,
					tokensBefore,
				},
			};
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			if (ctx.hasUI) {
				ctx.ui.notify(`Image compaction failed: ${message}`, "error");
			}
			// Fall back to default compaction
			// (回退到默认压缩)
			return;
		}
	});

	// Register manual command for forcing image compaction
	// (注册手动命令用于强制图片压缩)
	pi.registerCommand("image-compact", {
		description: "Force compaction to replace images with text summaries (强制压缩以将图片替换为文字摘要)",
		handler: async (_args, ctx) => {
			if (compactionInProgress) {
				ctx.ui.notify("Compaction already in progress", "warning");
				return;
			}
			compactionInProgress = true;
			ctx.compact({
				customInstructions:
					"Replace all image data with detailed text descriptions. Preserve all analysis results and conclusions about the images.",
				onComplete: () => {
					compactionInProgress = false;
					ctx.ui.notify("Image compaction complete", "info");
				},
				onError: (error) => {
					compactionInProgress = false;
					ctx.ui.notify(`Image compaction failed: ${error.message}`, "error");
				},
			});
		},
	});
}
