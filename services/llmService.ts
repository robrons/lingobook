import { CreateMLCEngine, MLCEngine, prebuiltAppConfig } from "@mlc-ai/web-llm";
import { TranslationSegment } from "../types";
import { getTranslation, saveTranslation } from "./db";

// Curated list of top 10 models for translation
// Selected based on multilingual capabilities, efficiency, and translation quality
const TOP_TRANSLATION_MODEL_IDS = [
    "Qwen2.5-3B-Instruct-q4f16_1-MLC",          // Excellent multilingual, efficient
    "Qwen2.5-7B-Instruct-q4f16_1-MLC",          // Best overall quality/performance balance
    "Llama-3.2-3B-Instruct-q4f16_1-MLC",        // Good general purpose, fast
    "Llama-3.1-8B-Instruct-q4f16_1-MLC",        // Strong multilingual support
    "gemma-2-2b-it-q4f16_1-MLC",                // Lightweight, decent quality
    "gemma-2-9b-it-q4f16_1-MLC",                // High quality, larger model
    "Phi-3.5-mini-instruct-q4f16_1-MLC",        // Very efficient, good for quick translation
    "SmolLM2-1.7B-Instruct-q4f16_1-MLC",        // Ultra-fast, lower quality
    "Mistral-7B-Instruct-v0.3-q4f16_1-MLC",     // Strong instruction following
    "Hermes-3-Llama-3.1-8B-q4f16_1-MLC"         // Excellent instruction model
];

export const AVAILABLE_MODELS = prebuiltAppConfig.model_list
    .filter(m => TOP_TRANSLATION_MODEL_IDS.includes(m.model_id))
    .map(m => ({
        id: m.model_id,
        name: m.model_id.replace(/-q4f16_1-MLC$/, ''), // Cleaner display name
        vram: m.vram_required_MB
    }))
    .sort((a, b) => {
        // Sort by model ID list order to keep recommended models first
        return TOP_TRANSLATION_MODEL_IDS.indexOf(a.id) - TOP_TRANSLATION_MODEL_IDS.indexOf(b.id);
    });

let currentModelId = AVAILABLE_MODELS[0].id;

export const getCurrentModelId = () => currentModelId;

export const setCurrentModelId = (id: string) => {
    if (id !== currentModelId) {
        currentModelId = id;
        engine = null; // Reset engine to force re-init with new model
    }
};

let engine: MLCEngine | null = null;

export const initLLM = async (progressCallback?: (report: { text: string }) => void) => {
    if (engine) return engine;

    engine = await CreateMLCEngine(currentModelId, {
        initProgressCallback: progressCallback,
    });
    return engine;
};

export const clearModelCache = async () => {
    if ('caches' in window) {
        try {
            const cacheNames = await caches.keys();
            const removalPromises = cacheNames.map(name => {
                if (name.includes("webllm") || name.includes(currentModelId)) {
                    console.log(`Deleting cache: ${name}`);
                    return caches.delete(name);
                }
                return Promise.resolve(false);
            });
            await Promise.all(removalPromises);
            console.log("Model cache cleared.");

            // Also reset the engine instance so it re-initializes
            engine = null;

            return true;
        } catch (error) {
            console.error("Error clearing cache:", error);
            return false;
        }
    }
    return false;
};

export const translate = async (
    text: string,
    sourceLanguage: string = "French",
    onStatusUpdate?: (status: string) => void
): Promise<string> => {
    // Check cache first
    try {
        const cachedTranslation = await getTranslation(text);
        if (cachedTranslation) {
            console.log("Cache hit for translation");
            return cachedTranslation;
        }
    } catch (error) {
        console.warn("Failed to check translation cache:", error);
    }

    // Initialize with a default logger if not already initialized
    // If onStatusUpdate is provided, use it to report loading progress
    const engineInstance = await initLLM((report) => {
        console.log("WebLLM Loading:", report.text);
        if (onStatusUpdate) {
            onStatusUpdate(report.text);
        }
    });

    if (onStatusUpdate) {
        onStatusUpdate("Translating...");
    }

    const prompt = `You are a professional translator. Your task is to translate ${sourceLanguage} text into English.

CRITICAL INSTRUCTIONS:
1. You MUST translate the text below from ${sourceLanguage} to English
2. Even if the text looks similar to English, you MUST still translate it properly
3. Output ONLY the English translation - no preambles, no explanations, no comments
4. Do NOT return the original ${sourceLanguage} text unchanged
5. If you're unsure, provide your best English translation

${sourceLanguage} text to translate:
${text}

English translation:`;

    const messages = [
        { role: "user" as const, content: prompt }
    ];

    try {
        const response = await engineInstance.chat.completions.create({
            messages,
            temperature: 0.3, // Slightly higher temperature for more variation
            max_tokens: 2048,
        });

        const rawOutput = response.choices[0]?.message?.content || "";
        console.log("Translation raw output:", rawOutput.substring(0, 100) + "...");

        // Clean up common LLM artifacts
        let cleaned = rawOutput.trim();

        // Remove common preambles
        const preambles = [
            /^Here is the translation:\s*/i,
            /^Translation:\s*/i,
            /^English translation:\s*/i,
            /^The translation is:\s*/i,
            /^Here's the translation:\s*/i,
        ];

        for (const pattern of preambles) {
            cleaned = cleaned.replace(pattern, '');
        }

        // Validate that we actually got a translation
        const normalizedInput = text.trim().toLowerCase().replace(/\s+/g, ' ');
        const normalizedOutput = cleaned.trim().toLowerCase().replace(/\s+/g, ' ');

        if (normalizedInput === normalizedOutput) {
            console.warn("⚠️ WARNING: Translation returned the same text!");
            console.warn("Original:", text.substring(0, 100));
            console.warn("Translation:", cleaned.substring(0, 100));

            // Try again with a more forceful prompt
            const forcefulPrompt = `CRITICAL: You MUST translate this ${sourceLanguage} text to English. Do NOT return the original text. Provide a proper English translation.

${sourceLanguage} text:
${text}

English translation (MUST be different from the original):`;

            const retryMessages = [
                { role: "user" as const, content: forcefulPrompt }
            ];

            try {
                console.log("Retrying translation with forceful prompt...");
                const retryResponse = await engineInstance.chat.completions.create({
                    messages: retryMessages,
                    temperature: 0.5, // Higher temperature for retry
                    max_tokens: 2048,
                });

                let retryOutput = retryResponse.choices[0]?.message?.content || "";
                retryOutput = retryOutput.trim();

                // Clean preambles from retry
                for (const pattern of preambles) {
                    retryOutput = retryOutput.replace(pattern, '');
                }

                // Check if retry succeeded
                const normalizedRetry = retryOutput.trim().toLowerCase().replace(/\s+/g, ' ');
                if (normalizedRetry !== normalizedInput) {
                    console.log("✓ Retry succeeded with different translation");
                    cleaned = retryOutput; // Update cleaned with retry result
                } else {
                    console.warn("⚠️ Retry still returned same text, returning original attempt");
                }
            } catch (retryError) {
                console.error("Retry translation failed:", retryError);
            }
        }

        // Save to cache
        try {
            await saveTranslation(text, cleaned);
        } catch (error) {
            console.warn("Failed to save translation to cache:", error);
        }

        return cleaned;
    } catch (error) {
        console.error("Translation error in translate():", error);
        throw error;
    }
};

export const summarize = async (
    text: string,
    onStatusUpdate?: (status: string) => void
): Promise<string> => {
    const engineInstance = await initLLM((report) => {
        if (onStatusUpdate) {
            onStatusUpdate(report.text);
        }
    });

    if (onStatusUpdate) {
        onStatusUpdate("Summarizing...");
    }

    // Truncate text if it's too long to fit in context with the prompt
    // 4096 tokens context ~ 16000 chars. Leave room for prompt and output.
    // Let's use a safe limit of around 10000 chars for input.
    const MAX_INPUT_CHARS = 10000;
    const truncatedText = text.length > MAX_INPUT_CHARS
        ? text.substring(0, MAX_INPUT_CHARS) + "..."
        : text;

    const prompt = `You are a professional literary assistant. Your task is to write a concise summary of the following text in English.

CRITICAL INSTRUCTIONS:
1. Read the text carefully.
2. Write a clear and concise summary in English.
3. Capture the main events and key points.
4. Do NOT translate the entire text, just summarize it.
5. Output ONLY the English summary.

Text to summarize:
${truncatedText}

English Summary:`;

    const messages = [
        { role: "user" as const, content: prompt }
    ];

    try {
        const response = await engineInstance.chat.completions.create({
            messages,
            temperature: 0.3,
            max_tokens: 1024,
        });

        const rawOutput = response.choices[0]?.message?.content || "";
        let cleaned = rawOutput.trim();

        // Remove common preambles
        const preambles = [
            /^Here is a summary:\s*/i,
            /^Summary:\s*/i,
            /^English summary:\s*/i,
            /^The summary is:\s*/i,
            /^Here's a summary:\s*/i,
        ];

        for (const pattern of preambles) {
            cleaned = cleaned.replace(pattern, '');
        }

        return cleaned;
    } catch (error) {
        console.error("Summarization error:", error);
        throw error;
    }
};

// Helper function to split text into chunks that fit within context window
// Rough estimate: 4 chars ≈ 1 token, context window is 4096 tokens
// We'll use a conservative limit to account for the prompt overhead
const MAX_CHUNK_CHARS = 2000; // ~500 tokens, leaving plenty of room for prompt

const splitIntoChunks = (text: string): string[] => {
    // If text is small enough, return as-is
    if (text.length <= MAX_CHUNK_CHARS) {
        return [text];
    }

    const chunks: string[] = [];
    const sentences = text.split(/([.!?]+\s+)/); // Split by sentence boundaries, keeping delimiters

    let currentChunk = "";

    for (let i = 0; i < sentences.length; i++) {
        const sentence = sentences[i];

        // If adding this sentence would exceed the limit
        if (currentChunk.length + sentence.length > MAX_CHUNK_CHARS) {
            // Save current chunk if it has content
            if (currentChunk.trim().length > 0) {
                chunks.push(currentChunk.trim());
            }
            // Start new chunk with this sentence
            currentChunk = sentence;
        } else {
            currentChunk += sentence;
        }
    }

    // Add remaining chunk
    if (currentChunk.trim().length > 0) {
        chunks.push(currentChunk.trim());
    }

    return chunks.length > 0 ? chunks : [text];
};

export const translateTextSegments = async (
    text: string,
    targetLanguage: string = "English", // Kept for compatibility
    onStatusUpdate?: (status: string) => void,
    onSegment?: (segment: TranslationSegment) => void
): Promise<TranslationSegment[]> => {
    if (!text || text.trim().length === 0) {
        console.log("translateTextSegments: No text to translate");
        return [];
    }

    try {
        console.log(`translateTextSegments: Starting translation of ${text.length} characters`);

        // Split into sentences using a simple regex that handles common sentence endings
        // This keeps the delimiter with the sentence
        const sentenceMatches = text.match(/[^.!?]+[.!?]+(\s+|$)|[^.!?]+$/g);
        const sentences = sentenceMatches ? sentenceMatches.map(s => s.trim()).filter(s => s.length > 0) : [text];

        const segments: TranslationSegment[] = [];

        for (let i = 0; i < sentences.length; i++) {
            const sentence = sentences[i];

            // Update status
            if (onStatusUpdate) {
                onStatusUpdate(`Translating sentence ${i + 1}/${sentences.length}...`);
            }

            // Translate sentence
            const translated = await translate(sentence, "French", onStatusUpdate);

            const segment = {
                original: sentence,
                translated: translated
            };

            segments.push(segment);

            // Emit segment immediately
            if (onSegment) {
                onSegment(segment);
            }
        }

        console.log(`translateTextSegments: Translated ${segments.length} segments successfully`);
        return segments;

    } catch (error) {
        console.error("Translation error in translateTextSegments:", error);
        const errorSegment = {
            original: text,
            translated: "Translation unavailable offline. Error: " + (error instanceof Error ? error.message : String(error))
        };
        if (onSegment) onSegment(errorSegment);
        return [errorSegment];
    }
};
