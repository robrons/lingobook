import React, { useEffect, useRef, useState, useCallback } from 'react';
import { ChevronLeft, Type, Columns, ArrowRight, ArrowLeft, List, Book, Image as ImageIcon, Languages, X, FileText } from 'lucide-react';
import { TranslationSegment, BookMetadata, TocItem } from '../types';
import { translateTextSegments, translate, summarize, AVAILABLE_MODELS, getCurrentModelId, setCurrentModelId, clearModelCache } from '../services/llmService';
import { updateBookProgress, saveUserPreferences, getUserPreferences } from '../services/db';
import { LoadingSpinner } from './LoadingSpinner';

interface ReaderProps {
    bookData: ArrayBuffer;
    bookId: number;
    initialLocation?: string;
    onBack: () => void;
}

interface SelectionState {
    text: string;
    cfiRange: string;
    rect: { top: number; left: number; width: number; height: number } | null;
}

// --- Text Extraction Helpers ---

const getText = (node: Node, depth: number = 0): string => {
    const indent = "  ".repeat(depth);

    if (node.nodeType === Node.TEXT_NODE) {
        const text = node.nodeValue || "";
        if (text.trim()) {
            // console.log(`${indent}TEXT_NODE: "${text.substring(0, 50)}${text.length > 50 ? '...' : ''}"`);
        }
        return text;
    }
    if (node.nodeType === Node.ELEMENT_NODE) {
        const el = node as Element;
        const tagName = el.tagName.toLowerCase();
        // console.log(`${indent}ELEMENT: <${tagName}>, children: ${node.childNodes.length}`);

        // Skip invisible/technical tags
        if (['script', 'style', 'noscript', 'meta', 'link', 'object', 'embed'].includes(tagName)) {
            // console.log(`${indent}  -> Skipping ${tagName}`);
            return "";
        }

        let content = "";
        const children = Array.from(node.childNodes);
        // console.log(`${indent}  Processing ${children.length} children`);
        for (const child of children) {
            content += getText(child, depth + 1);
        }

        // Add spacing for block elements to preserve paragraph structure
        if (['p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'tr', 'article', 'section', 'blockquote'].includes(tagName)) {
            return "\n" + content + "\n";
        }
        if (tagName === 'br') return "\n";

        return content;
    }
    // console.log(`${indent}UNKNOWN NODE TYPE: ${node.nodeType}`);
    return "";
};

const extractContentFromDoc = (d: Document): { text: string, hasImages: boolean } => {
    console.log("DEBUG: extractContentFromDoc called");
    console.log("DEBUG: Document type:", d.constructor.name);
    console.log("DEBUG: Has body?", !!d.body);
    console.log("DEBUG: documentElement:", d.documentElement?.tagName);

    // Try multiple approaches to find the body
    let body: Element | null = d.body;

    // For XHTML documents with namespaces, try getElementsByTagNameNS
    if (!body) {
        console.log("DEBUG: No body found, trying namespace approach");
        const xhtmlNS = "http://www.w3.org/1999/xhtml";
        const bodies = d.getElementsByTagNameNS(xhtmlNS, 'body');
        if (bodies && bodies.length > 0) {
            body = bodies[0];
            console.log("DEBUG: Found body via namespace");
        }
    }

    // Fallback to documentElement if still no body
    if (!body) {
        console.log("DEBUG: Still no body, using documentElement");
        body = d.documentElement;
    }

    if (!body) {
        console.log("DEBUG: No body or documentElement found!");
        return { text: "", hasImages: false };
    }

    console.log("DEBUG: Body found, tag:", body.tagName);
    console.log("DEBUG: Body children count:", body.children.length);

    // Detect visuals
    const images = body.getElementsByTagName('img');
    const svgs = body.getElementsByTagName('svg');
    const hasImages = images.length > 0 || svgs.length > 0;

    console.log("DEBUG: Images found:", images.length);

    // IMPORTANT: For XHTML documents, textContent is more reliable than recursive traversal
    // Try textContent first
    let raw = body.textContent || "";
    console.log("DEBUG: textContent length:", raw.length);
    console.log("DEBUG: textContent preview:", raw.substring(0, 100));

    // If textContent worked, clean it up
    if (raw.trim().length > 0) {
        // Collapse multiple newlines and whitespace
        raw = raw.replace(/\n\s*\n\s*\n/g, '\n\n').trim();
        console.log("DEBUG: Returning text from textContent, final length:", raw.length);
        return { text: raw, hasImages };
    }

    console.log("DEBUG: textContent empty, trying recursive getText");
    // Fallback to recursive getText if textContent didn't work
    raw = getText(body);

    // Collapse multiple newlines to max 2 to preserve paragraph breaks but remove huge gaps
    raw = raw.replace(/\n\s*\n\s*\n/g, '\n\n').trim();
    console.log("DEBUG: Returning text from recursive getText, length:", raw.length);

    return { text: raw, hasImages };
};

const extractTextFromChapter = (doc: any): { text: string, hasImages: boolean } => {
    let extraction = { text: "", hasImages: false };

    if (typeof doc === 'string') {
        const parser = new DOMParser();
        let htmlDoc = parser.parseFromString(doc, 'application/xhtml+xml');
        if (htmlDoc.querySelector('parsererror')) {
            htmlDoc = parser.parseFromString(doc, 'text/html');
        }
        extraction = extractContentFromDoc(htmlDoc);
    } else if (doc instanceof Document) {
        // For XMLDocument (XHTML), serialize to string and re-parse as HTML
        // This is necessary because XMLDocument.textContent doesn't work reliably
        if (doc instanceof XMLDocument || doc.contentType === 'application/xhtml+xml') {
            const serializer = new XMLSerializer();
            const xmlString = serializer.serializeToString(doc);

            // Parse as HTML for better textContent support
            const parser = new DOMParser();
            const htmlDoc = parser.parseFromString(xmlString, 'text/html');
            extraction = extractContentFromDoc(htmlDoc);
        } else {
            extraction = extractContentFromDoc(doc);
        }
    } else {
        // Try to handle as an object with document-like properties
        if (doc && typeof doc === 'object') {
            // Check if it has documentElement or body
            if ('documentElement' in doc) {
                const serializer = new XMLSerializer();
                try {
                    const xmlString = serializer.serializeToString(doc.documentElement);
                    const parser = new DOMParser();
                    const htmlDoc = parser.parseFromString(xmlString, 'text/html');
                    extraction = extractContentFromDoc(htmlDoc);
                } catch (e) {
                    console.error("DEBUG: Serialization failed:", e);
                }
            } else if ('body' in doc) {
                const serializer = new XMLSerializer();
                try {
                    const xmlString = serializer.serializeToString(doc.body);
                    const parser = new DOMParser();
                    const htmlDoc = parser.parseFromString(xmlString, 'text/html');
                    extraction = extractContentFromDoc(htmlDoc);
                } catch (e) {
                    console.error("DEBUG: Serialization failed:", e);
                }
            } else if ('outerHTML' in doc) {
                const parser = new DOMParser();
                const htmlDoc = parser.parseFromString(doc.outerHTML, 'text/html');
                extraction = extractContentFromDoc(htmlDoc);
            }
        }
    }

    // Fallback if text is empty but body has content
    if ((!extraction.text || extraction.text.trim().length === 0) && !extraction.hasImages) {
        let fallbackText = "";

        if (typeof doc === 'string') {
            const parser = new DOMParser();
            const d = parser.parseFromString(doc, 'text/html');
            if (d.body) {
                fallbackText = d.body.textContent || d.body.innerText || "";
            }

            // If still empty, try a more aggressive text extraction
            if (!fallbackText.trim()) {
                // Remove script and style tags
                let clean = doc.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '');
                clean = clean.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '');
                // Remove all HTML tags
                clean = clean.replace(/<[^>]+>/g, ' ');
                // Decode HTML entities
                const textarea = document.createElement('textarea');
                textarea.innerHTML = clean;
                fallbackText = textarea.value;
            }
        } else if (doc instanceof Document) {
            // Try body first
            if (doc.body) {
                fallbackText = doc.body.textContent || doc.body.innerText || "";
            }

            // Try with namespace
            if (!fallbackText.trim()) {
                const xhtmlNS = "http://www.w3.org/1999/xhtml";
                const bodies = doc.getElementsByTagNameNS(xhtmlNS, 'body');
                if (bodies && bodies.length > 0) {
                    fallbackText = bodies[0].textContent || "";
                }
            }

            // Last resort: documentElement
            if (!fallbackText.trim() && doc.documentElement) {
                fallbackText = doc.documentElement.textContent || "";
            }
        }

        if (fallbackText.trim().length > 0) {
            extraction.text = fallbackText.trim();
        }
    }

    return extraction;
};

export const Reader: React.FC<ReaderProps> = ({ bookData, bookId, initialLocation, onBack }) => {
    // --- State ---
    const [isReady, setIsReady] = useState(false);
    const [metadata, setMetadata] = useState<BookMetadata | null>(null);
    const [toc, setToc] = useState<TocItem[]>([]);
    const [currentLocation, setCurrentLocation] = useState<string>(initialLocation || ""); // CFI

    // View State
    const [showTranslation, setShowTranslation] = useState(false);
    const [fontSize, setFontSize] = useState(100); // Percentage
    const [preferencesLoaded, setPreferencesLoaded] = useState(false);

    const [showControls, setShowControls] = useState(true);
    const [showToc, setShowToc] = useState(false);
    const [showAppearance, setShowAppearance] = useState(false);

    // Content State
    const [rawText, setRawText] = useState<string>("");
    const [translatedSegments, setTranslatedSegments] = useState<TranslationSegment[]>([]);
    const [isTranslating, setIsTranslating] = useState(false);
    const [statusMessage, setStatusMessage] = useState("Translating...");
    const [pageType, setPageType] = useState<'text' | 'image' | 'empty'>('text');

    // Selection & Translation State
    const [selection, setSelection] = useState<SelectionState | null>(null);
    const [showTranslateButton, setShowTranslateButton] = useState(false);
    const [showTranslationResult, setShowTranslationResult] = useState(false);
    const [translationResult, setTranslationResult] = useState<string>("");
    const [isTranslatingSelection, setIsTranslatingSelection] = useState(false);
    const [showCacheConfirm, setShowCacheConfirm] = useState(false);

    // Summary State
    const [showSummary, setShowSummary] = useState(false);
    const [summaryText, setSummaryText] = useState("");
    const [isSummarizing, setIsSummarizing] = useState(false);
    const [selectedModel, setSelectedModel] = useState(getCurrentModelId());

    // Refs
    const viewerRef = useRef<HTMLDivElement>(null);
    const bookRef = useRef<any>(null); // ePub.Book
    const renditionRef = useRef<any>(null); // ePub.Rendition
    const selectionTimeoutRef = useRef<NodeJS.Timeout | null>(null);
    const anchorTextRef = useRef<string | null>(null); // Store text to scroll to

    // Scroll State
    const [scrollToIndex, setScrollToIndex] = useState<number | null>(null);

    // --- Load User Preferences ---
    useEffect(() => {
        getUserPreferences().then(prefs => {
            if (prefs.fontSize) {
                setFontSize(prefs.fontSize);
            }
            setPreferencesLoaded(true);
        }).catch(err => {
            console.error('Failed to load user preferences:', err);
            setPreferencesLoaded(true);
        });
    }, []);

    // --- Initialization ---
    useEffect(() => {
        if (!window.ePub) return;

        const book = window.ePub(bookData);
        bookRef.current = book;

        book.loaded.metadata.then((meta: any) => {
            setMetadata({
                title: meta.title,
                author: meta.creator,
            });
        });

        book.loaded.navigation.then((nav: any) => {
            const tocItems = nav.toc.map((item: any) => ({
                id: item.id,
                label: item.label,
                href: item.href
            }));
            setToc(tocItems);
        });

        return () => {
            if (bookRef.current) {
                bookRef.current.destroy();
            }
        };
    }, [bookData]);



    // --- Rendering (Original Mode) ---
    useEffect(() => {
        if (!bookRef.current || !viewerRef.current) return;

        // Destroy previous rendition if exists to avoid duplicates
        if (renditionRef.current) {
            try { renditionRef.current.destroy(); } catch (e) { }
        }

        const rendition = bookRef.current.renderTo(viewerRef.current, {
            width: '100%',
            height: '100%',
            flow: 'paginated',
            manager: 'default',
        });
        renditionRef.current = rendition;

        const displayPromise = currentLocation
            ? rendition.display(currentLocation)
            : rendition.display();

        displayPromise.then(() => {
            setIsReady(true);
            // Apply sepia (calm) theme
            applyTheme(rendition);
        });

        rendition.on('relocated', (location: any) => {
            setCurrentLocation(location.start.cfi);

            // Save progress (debounced could be better, but for now direct save is okay as it's async)
            // We can add a small timeout if performance is an issue, but IndexedDB is fast enough
            updateBookProgress(bookId, location.start.cfi).catch(err => {
                console.error("Failed to save progress:", err);
            });

            // Clear selection on page turn
            setSelection(null);
            setShowTranslateButton(false);
            setShowTranslationResult(false);
        });

        // Handle clicks to toggle controls
        // Note: We don't clear selection here because it creates a race condition with 'selected' event
        // Selection will be cleared on page navigation or when user explicitly dismisses it
        rendition.on('click', () => {
            setShowControls(prev => !prev);
            setShowAppearance(false);
            setShowToc(false);
        });

        // Handle Selection
        rendition.on('selected', (cfiRange: string, contents: any) => {
            const range = contents.range(cfiRange);
            const text = range.toString();

            if (text && text.trim().length > 0) {
                // Get coordinates
                // The range.getBoundingClientRect() is relative to the iframe document
                // We need to adjust for the iframe's position if needed, but usually epub.js handles this via the event or we access the iframe
                // Actually, `contents` is the Contents object.
                // We can get the client rect of the selection.

                // Note: Getting exact screen coordinates from inside the iframe can be tricky.
                // A robust way is to use the range from the iframe's window.
                const rect = range.getBoundingClientRect();

                // We need to account for the viewer's position if the iframe is offset, 
                // but usually viewerRef is the container.
                // The rect is relative to the viewport of the iframe.
                // We need to add the iframe's offset relative to the main window.

                const iframe = viewerRef.current?.querySelector('iframe');
                const iframeRect = iframe?.getBoundingClientRect();

                if (iframeRect) {
                    setSelection({
                        text: text,
                        cfiRange: cfiRange,
                        rect: {
                            top: rect.top + iframeRect.top,
                            left: rect.left + iframeRect.left,
                            width: rect.width,
                            height: rect.height
                        }
                    });
                    setShowTranslateButton(true);
                    // Don't show controls when selecting text
                    setShowControls(false);
                }
            }
        });

        return () => {
            // Clear any pending selection timeout
            if (selectionTimeoutRef.current) {
                clearTimeout(selectionTimeoutRef.current);
            }
        };
    }, [bookData]);

    // --- Inline Translation - Full Page Replacement ---
    const removeTranslations = useCallback(() => {
        if (!renditionRef.current) return;

        try {
            const contents = renditionRef.current.getContents();
            if (!contents || contents.length === 0) return;

            const doc = contents[0].document;

            // Check if we have a backup
            const backup = doc.getElementById('lingobook-original-content');
            if (backup) {
                // Restore original content
                const container = doc.getElementById('lingobook-bilingual-container');
                if (container && container.parentNode && backup.firstChild) {
                    // Get the original body content
                    const originalBody = backup.firstChild as HTMLElement;
                    // Replace bilingual container's parent (body) children with original
                    while (doc.body.firstChild) {
                        doc.body.removeChild(doc.body.firstChild);
                    }
                    // Restore from backup
                    while (originalBody.firstChild) {
                        doc.body.appendChild(originalBody.firstChild);
                    }
                }
                backup.remove();
            }

        } catch (e) {
            console.error("Error removing translations:", e);
        }
    }, []);

    const injectTranslations = useCallback(() => {
        if (!renditionRef.current || translatedSegments.length === 0) return;

        try {
            const contents = renditionRef.current.getContents();
            if (!contents || contents.length === 0) return;

            const doc = contents[0].document;
            const body = doc.body;

            // Always remove previous container if it exists to allow updates
            const oldContainer = doc.getElementById('lingobook-bilingual-container');
            if (oldContainer) oldContainer.remove();

            // If we don't have a backup, create it now
            let backup = doc.getElementById('lingobook-original-content');
            if (!backup) {
                console.log("DEBUG: Creating backup of original content");
                backup = doc.createElement('div');
                backup.id = 'lingobook-original-content';
                backup.style.display = 'none';
                const bodyClone = body.cloneNode(true) as HTMLElement;
                backup.appendChild(bodyClone);
                body.appendChild(backup);
            }

            console.log(`DEBUG: Rebuilding bilingual view with ${translatedSegments.length} segments`);

            // Create bilingual container
            const bilingualContainer = doc.createElement('div');
            bilingualContainer.id = 'lingobook-bilingual-container';
            bilingualContainer.style.cssText = `
                padding: 2rem 1.5rem;
                max-width: 900px;
                margin: 0 auto;
                font-family: inherit;
                line-height: 1.8;
            `;

            // Add each segment as a bilingual block
            translatedSegments.forEach((segment, index) => {
                if (!segment.original) return;

                const block = doc.createElement('div');
                block.id = `segment-${index}`; // Add ID for scrolling
                block.style.cssText = `
                    margin-bottom: 2rem;
                    padding-bottom: 1.5rem;
                    border-bottom: 1px solid rgba(231, 229, 228, 0.5);
                `;

                // Original text
                const originalP = doc.createElement('p');
                originalP.style.cssText = `
                    margin: 0 0 0.75rem 0;
                    color: #292524;
                    font-size: 1em;
                    line-height: 1.8;
                `;
                originalP.textContent = segment.original;
                block.appendChild(originalP);

                // Translated text
                if (segment.translated) {
                    const translatedP = doc.createElement('p');
                    translatedP.style.cssText = `
                        margin: 0;
                        color: #78716c;
                        font-style: italic;
                        font-size: 0.95em;
                        line-height: 1.7;
                    `;
                    translatedP.textContent = segment.translated;
                    block.appendChild(translatedP);
                }

                bilingualContainer.appendChild(block);
            });

            //  Remove all children except backup
            while (body.firstChild && body.firstChild !== backup) {
                body.removeChild(body.firstChild);
            }

            // Insert bilingual container at the beginning
            body.insertBefore(bilingualContainer, backup);

            console.log(`DEBUG: Bilingual view created/updated successfully`);

        } catch (e) {
            console.error("Error injecting translations:", e);
        }
    }, [translatedSegments]);

    // Effect to trigger injection
    useEffect(() => {
        if (showTranslation && translatedSegments.length > 0) {
            injectTranslations();
        } else if (!showTranslation) {
            removeTranslations();
        }
    }, [showTranslation, translatedSegments, injectTranslations, removeTranslations]);

    // --- Content Extraction & Translation ---
    const fetchAndTranslateCurrentChapter = useCallback(async () => {
        if (!bookRef.current || !renditionRef.current) return;

        setIsTranslating(true);
        setStatusMessage("Translating...");
        setTranslatedSegments([]);
        setPageType('text');
        setScrollToIndex(null); // Reset scroll target

        try {
            // Extract text from ONLY the visible viewport using CFI range
            console.log("DEBUG: Extracting text from visible page using CFI range");

            // Get the current visible location (start and end CFI)
            const location = renditionRef.current.currentLocation();
            if (!location || !location.start || !location.end) {
                throw new Error("No current location available");
            }

            console.log("DEBUG: Visible range - Start CFI:", location.start.cfi);
            console.log("DEBUG: Visible range - End CFI:", location.end.cfi);

            const contents = renditionRef.current.getContents();
            if (!contents || contents.length === 0) {
                throw new Error("No contents available in rendition");
            }

            // Get the visible range from the CFI
            const startRange = contents[0].range(location.start.cfi);
            const endRange = contents[0].range(location.end.cfi);

            if (!startRange || !endRange) {
                throw new Error("Could not create ranges from CFI");
            }

            // Create a range that spans from start to end of visible content
            const visibleRange = startRange.cloneRange();
            visibleRange.setEnd(endRange.endContainer, endRange.endOffset);

            // Extract text from only this visible range
            let pageText = visibleRange.toString();
            console.log("DEBUG: Extracted visible text length:", pageText.length);
            console.log("DEBUG: Text preview:", pageText.substring(0, 200));

            // Check for images in the visible content
            const doc = contents[0].document;
            let hasImages = false;

            // Try to detect if there are images in the visible range
            // This is approximate since we're working with a text range
            if (doc && doc.body) {
                const allImages = doc.body.getElementsByTagName('img');
                const allSvgs = doc.body.getElementsByTagName('svg');
                hasImages = allImages.length > 0 || allSvgs.length > 0;
            }

            if (!pageText || pageText.trim().length === 0) {
                setRawText("");
                if (hasImages) {
                    setPageType('image');
                    setTranslatedSegments([{
                        original: "",
                        translated: ""
                    }]);
                } else {
                    setPageType('empty');
                    setTranslatedSegments([]);
                }
                setIsTranslating(false);
                return;
            }

            // Clean up the text
            pageText = pageText.trim();

            setPageType('text');
            setRawText(pageText);

            // Translate ONLY the visible page text
            await translateTextSegments(
                pageText,
                "English",
                (status) => {
                    setStatusMessage(status);
                },
                (segment) => {
                    setTranslatedSegments(prev => {
                        const newSegments = [...prev, segment];

                        // Check if we need to scroll to a specific segment
                        if (anchorTextRef.current && prev.length < newSegments.length) {
                            const newSegmentIndex = newSegments.length - 1;
                            const newSegment = newSegments[newSegmentIndex];

                            if (newSegment.original.includes(anchorTextRef.current) ||
                                anchorTextRef.current.includes(newSegment.original)) {
                                console.log(`DEBUG: Found matching segment at index ${newSegmentIndex}`);
                                setScrollToIndex(newSegmentIndex);
                                anchorTextRef.current = null;
                            }
                        }
                        return newSegments;
                    });
                }
            );

        } catch (error) {
            console.error("Error extracting/translating:", error);

            // Provide more specific error messages based on the error type
            let errorMessage = "Please try navigating to the next page.";
            let originalMessage = "Error loading content.";

            if (error instanceof Error) {
                console.error("Error details:", error.message, error.stack);

                if (error.message.includes("No current location")) {
                    errorMessage = "Unable to determine visible content. Try navigating to another page.";
                } else if (error.message.includes("No contents available")) {
                    errorMessage = "Page content not ready. Please try again in a moment.";
                } else if (error.message.includes("Could not create ranges")) {
                    errorMessage = "Unable to extract visible text. Try navigating to another page.";
                }
            }

            setTranslatedSegments([{
                original: originalMessage,
                translated: errorMessage
            }]);
        } finally {
            setIsTranslating(false);
        }
    }, []);

    // --- Translation Toggle Handler ---
    const handleTranslationToggle = () => {
        const newValue = !showTranslation;
        setShowTranslation(newValue);
        setShowAppearance(false);

        if (newValue) {
            // Trigger translation when enabled
            setTimeout(() => fetchAndTranslateCurrentChapter(), 0);
        } else {
            // Clear translations when disabled
            setTranslatedSegments([]);
            // TODO: Remove injected translations from DOM
        }
    };

    // --- Scroll Effect ---
    useEffect(() => {
        if (scrollToIndex !== null) {
            const element = document.getElementById(`segment-${scrollToIndex}`);
            if (element) {
                console.log(`DEBUG: Scrolling to segment-${scrollToIndex}`);
                element.scrollIntoView({ behavior: 'smooth', block: 'center' });
                setScrollToIndex(null); // Clear after scrolling
            }
        }
    }, [scrollToIndex, translatedSegments]);

    // --- Theming Helpers ---
    // Apply the sepia (calm) theme and font size to a rendition
    const applyTheme = (rendition: any) => {
        if (!rendition) {
            console.warn('applyTheme called but rendition is null');
            return;
        }

        console.log(`Applying sepia theme, fontSize: ${fontSize}%`);

        // Set font size
        rendition.themes.fontSize(`${fontSize}%`);

        // Register and apply sepia theme
        rendition.themes.register('sepia', {
            body: {
                color: '#57534e !important',
                background: '#f5f5f4 !important'
            }
        });

        rendition.themes.select('sepia');

        console.log('Sepia theme applied to rendition');
    };

    // Apply theme when fontSize changes
    useEffect(() => {
        if (renditionRef.current) {
            console.log('Font size changed, applying to rendition');
            applyTheme(renditionRef.current);
        } else {
            console.warn('Font size changed but renditionRef.current is null');
        }
    }, [fontSize]);



    // --- Save Font Size Preference ---
    useEffect(() => {
        if (preferencesLoaded) {
            saveUserPreferences({ fontSize }).catch(err => {
                console.error('Failed to save font size preference:', err);
            });
        }
    }, [fontSize, preferencesLoaded]);

    // --- Navigation ---
    const navigate = (direction: 'next' | 'prev') => {
        // Always use page-based navigation
        if (direction === 'next') renditionRef.current?.next();
        else renditionRef.current?.prev();
    };

    const handleTocClick = (href: string) => {
        if (renditionRef.current) {
            renditionRef.current.display(href);
            setShowToc(false);
        }
    };

    // --- Translation Selection Handler ---
    const handleTranslateSelection = async () => {
        if (!selection) return;

        setShowTranslateButton(false);
        setShowTranslationResult(true);
        setIsTranslatingSelection(true);
        setTranslationResult(""); // Clear previous

        try {
            const result = await translate(selection.text);
            setTranslationResult(result);
        } catch (error) {
            console.error("Selection translation error:", error);
            setTranslationResult("Failed to translate text.");
        } finally {
            setIsTranslatingSelection(false);
        }
    };

    const handleClearCache = async () => {
        const success = await clearModelCache();
        if (success) {
            alert("Model cache cleared successfully. The page will reload.");
            window.location.reload();
        } else {
            alert("Failed to clear model cache.");
            setShowCacheConfirm(false);
        }
    };

    const handleSummarize = async () => {
        setShowSummary(true);
        setIsSummarizing(true);
        setSummaryText("");
        setShowControls(false);

        try {
            // Reuse the extraction logic or just use rawText if available
            let textToSummarize = rawText;

            // If rawText is empty (e.g. we haven't translated yet), we need to extract it
            if (!textToSummarize) {
                // This is a simplified extraction similar to fetchAndTranslateCurrentChapter
                // In a real app we might want to refactor extraction into a reusable function
                if (bookRef.current) {
                    let currentCfi = currentLocation;
                    if (!currentCfi && renditionRef.current) {
                        const loc = renditionRef.current.currentLocation();
                        if (loc && loc.start) currentCfi = loc.start.cfi;
                    }

                    const spineItem = currentCfi
                        ? bookRef.current.spine.get(currentCfi)
                        : bookRef.current.spine.get(0);

                    if (spineItem) {
                        const doc = await spineItem.load(bookRef.current.load.bind(bookRef.current));
                        const extraction = extractTextFromChapter(doc);
                        textToSummarize = extraction.text;
                    }
                }
            }

            if (!textToSummarize || textToSummarize.trim().length === 0) {
                setSummaryText("No text found to summarize.");
                setIsSummarizing(false);
                return;
            }

            const summary = await summarize(textToSummarize, (status) => {
                // Optional: update a status specifically for summary if needed
                // For now we just use the isSummarizing flag
            });
            setSummaryText(summary);

        } catch (error) {
            console.error("Summary error:", error);
            setSummaryText("Failed to generate summary. Please try again.");
        } finally {
            setIsSummarizing(false);
        }
    };


    // --- Custom View Rendering (Removed - now using inline translation) ---
    // Split and Interleaved modes have been removed.
    // Translation is now injected directly into the EPUB view.


    // --- Styles for Sepia Theme ---
    const getThemeBg = () => 'bg-[#f8f4e9]';
    const getThemeText = () => 'text-stone-800';

    return (
        <div className={`relative w-full h-full flex flex-col overflow-hidden transition-colors duration-300 ${getThemeBg()} ${getThemeText()}`}>

            {/* --- Top Bar --- */}
            <div
                className={`
            absolute top-0 left-0 right-0 z-50 flex items-center justify-between px-4 py-3 
            transition-transform duration-300 ease-in-out border-b backdrop-blur-md
            ${showControls ? 'translate-y-0' : '-translate-y-full'}
            bg-[#f8f4e9]/80 border-stone-300
        `}
            >
                <button onClick={onBack} className="p-2 rounded-full hover:bg-stone-200/20 transition-colors">
                    <ChevronLeft className="w-6 h-6" />
                </button>

                <div className="flex items-center gap-2">
                    <button onClick={() => setShowToc(!showToc)} className="p-2 rounded-full hover:bg-stone-200/20">
                        <List className="w-5 h-5" />
                    </button>
                    <button onClick={() => setShowAppearance(!showAppearance)} className="p-2 rounded-full hover:bg-stone-200/20">
                        <Type className="w-5 h-5" />
                    </button>
                    <button onClick={handleSummarize} className="p-2 rounded-full hover:bg-stone-200/20" title="Summarize Chapter">
                        <FileText className="w-5 h-5" />
                    </button>
                </div>
            </div>

            {/* --- Main Viewer Area --- */}
            <div className="flex-1 relative w-full h-full overflow-hidden">
                {/* EPUB View - Always visible */}
                <div
                    ref={viewerRef}
                    className="w-full h-full"
                />


                {/* --- Floating Translate Button --- */}
                {showTranslateButton && selection && selection.rect && (
                    <div
                        className="absolute z-[100] transform -translate-x-1/2 -translate-y-full"
                        style={{
                            top: selection.rect.top - 10, // 10px above selection
                            left: selection.rect.left + (selection.rect.width / 2)
                        }}
                    >
                        <button
                            onClick={handleTranslateSelection}
                            className="
                                flex items-center gap-2 px-4 py-2 rounded-full shadow-xl
                                bg-stone-900 text-white hover:bg-stone-800 hover:scale-105
                                transition-all duration-200 animate-in fade-in zoom-in
                            "
                        >
                            <Languages className="w-4 h-4" />
                            <span className="text-sm font-medium">Translate</span>
                        </button>
                    </div>
                )}

                {/* --- Summary Modal --- */}
                {showSummary && (
                    <div className="absolute inset-0 z-[60] bg-black/50 backdrop-blur-sm flex items-center justify-center p-4">
                        <div className={`
                            w-full max-w-2xl max-h-[80vh] rounded-2xl shadow-2xl overflow-hidden flex flex-col
                            bg-[#f8f4e9] text-stone-800
                        `}>
                            <div className="flex items-center justify-between p-4 border-b border-stone-200/10">
                                <h3 className="font-serif-apple font-semibold text-lg flex items-center gap-2">
                                    <FileText className="w-5 h-5" />
                                    Chapter Summary
                                </h3>
                                <button
                                    onClick={() => setShowSummary(false)}
                                    className="p-2 rounded-full hover:bg-stone-500/10 transition-colors"
                                >
                                    <X className="w-5 h-5" />
                                </button>
                            </div>

                            <div className="p-6 overflow-y-auto">
                                {isSummarizing ? (
                                    <div className="flex flex-col items-center justify-center py-12 space-y-4">
                                        <div className="w-8 h-8 border-2 border-stone-400 border-t-transparent rounded-full animate-spin"></div>
                                        <p className="text-stone-500 animate-pulse">Generating summary...</p>
                                    </div>
                                ) : (
                                    <div className="prose prose-stone max-w-none dark:prose-invert">
                                        <p className="font-serif-apple leading-relaxed whitespace-pre-wrap text-lg">
                                            {summaryText}
                                        </p>
                                    </div>
                                )}
                            </div>
                        </div>
                    </div>
                )}

                {/* --- Translation Result Popover --- */}
                {
                    showTranslationResult && (
                        <div className="absolute inset-0 z-[100] flex items-center justify-center p-6 bg-black/20 backdrop-blur-sm">
                            <div
                                className={`
                                w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden
                                bg-[#f8f4e9] border border-stone-300
                            `}
                            >
                                {/* Header */}
                                <div className="flex items-center justify-between px-6 py-4 border-b border-stone-200/10">
                                    <h3 className="font-semibold text-sm uppercase tracking-wider opacity-70">Translation</h3>
                                    <button
                                        onClick={() => setShowTranslationResult(false)}
                                        className="p-1 rounded-full hover:bg-stone-200/20 transition-colors"
                                    >
                                        <X className="w-5 h-5" />
                                    </button>
                                </div>

                                {/* Content */}
                                <div className="p-6 max-h-[60vh] overflow-y-auto">
                                    <div className="space-y-6">
                                        {/* Original Text */}
                                        <div className="space-y-2">
                                            <span className="text-xs font-bold uppercase tracking-widest opacity-40">Original</span>
                                            <p className="font-serif-apple text-lg leading-relaxed opacity-90">
                                                {selection?.text}
                                            </p>
                                        </div>

                                        {/* Divider */}
                                        <div className="h-px w-full bg-stone-200/20"></div>

                                        {/* Translated Text */}
                                        <div className="space-y-2">
                                            <span className="text-xs font-bold uppercase tracking-widest text-orange-600">English</span>
                                            {isTranslatingSelection ? (
                                                <div className="py-4 flex items-center gap-3 text-stone-500">
                                                    <div className="w-4 h-4 border-2 border-current border-t-transparent rounded-full animate-spin"></div>
                                                    <span className="text-sm">Translating...</span>
                                                </div>
                                            ) : (
                                                <p className="font-serif-apple text-lg leading-relaxed">
                                                    {translationResult}
                                                </p>
                                            )}
                                        </div>
                                    </div>
                                </div>
                            </div>

                            {/* Click outside to close */}
                            <div
                                className="absolute inset-0 -z-10"
                                onClick={() => setShowTranslationResult(false)}
                            ></div>
                        </div>
                    )
                }

            </div >

            {/* --- Bottom Bar (Navigation) --- */}
            < div
                className={`
            absolute bottom-0 left-0 right-0 z-50 px-6 py-4 flex items-center justify-between
            transition-transform duration-300 ease-in-out backdrop-blur-md border-t
            ${showControls ? 'translate-y-0' : 'translate-y-full'}
            bg-[#f8f4e9]/80 border-stone-300
        `}
            >
                <button onClick={() => navigate('prev')} className="p-2 text-stone-500 hover:text-stone-900 dark:hover:text-stone-100">
                    <ArrowLeft className="w-5 h-5" />
                </button>

                <span className="text-xs font-medium uppercase tracking-wider opacity-50 truncate max-w-[200px] select-none">
                    {metadata ? metadata.title : 'Chapter'}
                </span>

                <button onClick={() => navigate('next')} className="p-2 text-stone-500 hover:text-stone-900 dark:hover:text-stone-100">
                    <ArrowRight className="w-5 h-5" />
                </button>
            </div >

            {/* --- Appearance Popover --- */}
            {
                showAppearance && (
                    <div className={`
            absolute top-16 right-4 w-72 rounded-xl shadow-2xl z-[60] p-4 transform transition-all
            bg-[#f8f4e9]/95 backdrop-blur-xl border border-stone-300
          `}>
                        {/* Translation Toggle */}
                        <div className="flex items-center justify-between px-2 mb-4 pb-4 border-b border-stone-200/20">
                            <span className="text-[10px] uppercase tracking-widest opacity-50 font-semibold">Translation</span>
                            <button
                                onClick={handleTranslationToggle}
                                className={`relative w-12 h-6 rounded-full transition-colors ${showTranslation ? 'bg-orange-500' : 'bg-stone-300'
                                    }`}
                            >
                                <div className={`absolute top-0.5 left-0.5 w-5 h-5 bg-white rounded-full transition-transform ${showTranslation ? 'translate-x-full' : ''
                                    }`} />
                            </button>
                        </div>



                        {/* Font Size */}
                        <div className="flex items-center gap-3 px-2">
                            <button
                                onClick={() => setFontSize(prev => Math.max(80, prev - 10))}
                                className="p-1 hover:bg-stone-200/30 rounded transition-colors"
                                aria-label="Decrease font size"
                            >
                                <Type className="w-4 h-4 opacity-50" />
                            </button>
                            <input
                                type="range"
                                min="80"
                                max="150"
                                value={fontSize}
                                onChange={(e) => setFontSize(parseInt(e.target.value))}
                                className="w-full h-1 bg-stone-200 rounded-lg appearance-none cursor-pointer accent-orange-500"
                            />
                            <button
                                onClick={() => setFontSize(prev => Math.min(150, prev + 10))}
                                className="p-1 hover:bg-stone-200/30 rounded transition-colors"
                                aria-label="Increase font size"
                            >
                                <Type className="w-6 h-6 opacity-50" />
                            </button>
                        </div>

                        {/* Model Info */}
                        <div className="mt-4 pt-4 border-t border-stone-200/20 px-2">
                            <p className="text-[10px] uppercase tracking-widest opacity-50 font-semibold mb-2">Translation Model</p>

                            <select
                                value={selectedModel}
                                onChange={(e) => {
                                    const newModel = e.target.value;
                                    setSelectedModel(newModel);
                                    setCurrentModelId(newModel);
                                }}
                                className={`w-full p-2 text-xs rounded-md border mb-2 outline-none focus:ring-2 focus:ring-orange-500/50 bg-stone-50 border-stone-200 text-stone-800`}
                            >
                                {AVAILABLE_MODELS.map(m => (
                                    <option key={m.id} value={m.id}>
                                        {m.name} {m.vram ? `(${Math.round(m.vram)}MB VRAM)` : ''}
                                    </option>
                                ))}
                            </select>

                            {!showCacheConfirm ? (
                                <button
                                    onClick={(e) => {
                                        e.stopPropagation();
                                        setShowCacheConfirm(true);
                                    }}
                                    className="mt-3 w-full py-2 text-xs font-medium text-red-500 bg-red-50 hover:bg-red-100 rounded-md transition-colors"
                                >
                                    Clear Model Cache
                                </button>
                            ) : (
                                <div className="mt-3 space-y-2">
                                    <p className="text-[10px] text-red-600 font-medium leading-tight">
                                        Are you sure? The model will need to be redownloaded.
                                    </p>
                                    <div className="flex gap-2">
                                        <button
                                            onClick={(e) => {
                                                e.stopPropagation();
                                                setShowCacheConfirm(false);
                                            }}
                                            className="flex-1 py-1.5 text-xs font-medium text-stone-600 bg-stone-100 hover:bg-stone-200 rounded-md transition-colors"
                                        >
                                            Cancel
                                        </button>
                                        <button
                                            onClick={(e) => {
                                                e.stopPropagation();
                                                handleClearCache();
                                            }}
                                            className="flex-1 py-1.5 text-xs font-medium text-white bg-red-500 hover:bg-red-600 rounded-md transition-colors"
                                        >
                                            Confirm
                                        </button>
                                    </div>
                                </div>
                            )}
                        </div>
                    </div>
                )
            }

            {/* --- Table of Contents Popover --- */}
            {
                showToc && (
                    <div className={`
            absolute top-0 bottom-0 left-0 w-80 z-[60] shadow-2xl overflow-y-auto transition-transform
            bg-[#f8f4e9]/95 backdrop-blur-xl border-r border-stone-300
          `}>
                        <div className="p-4 border-b border-stone-200/10 flex items-center justify-between sticky top-0 bg-inherit backdrop-blur-xl">
                            <span className="font-semibold text-sm">Contents</span>
                            <button onClick={() => setShowToc(false)} className="p-1 rounded-full hover:bg-stone-200/20">
                                <ArrowLeft className="w-5 h-5" />
                            </button>
                        </div>
                        <div className="p-2">
                            {toc.map((item, i) => (
                                <button
                                    key={i}
                                    onClick={() => handleTocClick(item.href)}
                                    className="w-full text-left px-4 py-3 text-sm rounded-lg hover:bg-stone-200/20 truncate"
                                >
                                    {item.label}
                                </button>
                            ))}
                            {toc.length === 0 && (
                                <div className="p-8 text-center text-stone-400 text-sm">
                                    No table of contents found.
                                </div>
                            )}
                        </div>
                    </div>
                )
            }

            {/* Backdrop for popovers */}
            {
                (showAppearance || showToc) && (
                    <div
                        className="absolute inset-0 z-40 bg-black/5"
                        onClick={() => { setShowAppearance(false); setShowToc(false); }}
                    />
                )
            }

        </div >
    );
};