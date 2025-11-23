import JSZip from 'jszip';

export interface BookMetadata {
    title: string;
    author: string;
    coverUrl: string | null;
}

export const extractMetadata = async (data: ArrayBuffer): Promise<BookMetadata> => {
    const zip = await JSZip.loadAsync(data);

    // Step 1: Parse container.xml to find the OPF file path
    const containerFile = zip.file('META-INF/container.xml');
    if (!containerFile) {
        throw new Error('Invalid EPUB: META-INF/container.xml not found');
    }

    const containerText = await containerFile.async('text');
    const containerParser = new DOMParser();
    const containerDoc = containerParser.parseFromString(containerText, 'application/xml');

    const rootfileElement = containerDoc.querySelector('rootfile');
    const opfPath = rootfileElement?.getAttribute('full-path');

    if (!opfPath) {
        throw new Error('Invalid EPUB: OPF path not found in container.xml');
    }

    // Step 2: Parse the OPF file to extract metadata
    const opfFile = zip.file(opfPath);
    if (!opfFile) {
        throw new Error(`Invalid EPUB: OPF file not found at ${opfPath}`);
    }

    const opfText = await opfFile.async('text');
    const opfParser = new DOMParser();
    const opfDoc = opfParser.parseFromString(opfText, 'application/xml');

    // Extract title (try both namespaced and non-namespaced)
    let title = opfDoc.querySelector('metadata title, metadata dc\\:title')?.textContent?.trim() || 'Unknown Title';

    // Extract author/creator
    let author = opfDoc.querySelector('metadata creator, metadata dc\\:creator')?.textContent?.trim() || 'Unknown Author';

    // Step 3: Extract cover image
    let coverUrl: string | null = null;

    // Method 1: Look for cover image in manifest with properties="cover-image" (EPUB 3)
    const manifestItems = opfDoc.querySelectorAll('manifest item');
    let coverHref: string | null = null;

    for (const item of Array.from(manifestItems)) {
        const properties = item.getAttribute('properties');
        if (properties?.includes('cover-image')) {
            coverHref = item.getAttribute('href');
            break;
        }
    }

    // Method 2: Look for meta with name="cover" (EPUB 2)
    if (!coverHref) {
        const coverMeta = opfDoc.querySelector('metadata meta[name="cover"]');
        if (coverMeta) {
            const coverId = coverMeta.getAttribute('content');
            if (coverId) {
                const coverItem = opfDoc.querySelector(`manifest item[id="${coverId}"]`);
                coverHref = coverItem?.getAttribute('href') || null;
            }
        }
    }

    // Method 3: Look for common cover filenames
    if (!coverHref) {
        const commonCoverNames = ['cover.jpg', 'cover.jpeg', 'cover.png', 'cover.gif'];
        for (const item of Array.from(manifestItems)) {
            const href = item.getAttribute('href')?.toLowerCase() || '';
            if (commonCoverNames.some(name => href.includes(name))) {
                coverHref = item.getAttribute('href');
                break;
            }
        }
    }

    // Extract the cover image file
    if (coverHref) {
        // Resolve the path relative to the OPF file
        const opfDir = opfPath.substring(0, opfPath.lastIndexOf('/'));
        const coverPath = opfDir ? `${opfDir}/${coverHref}` : coverHref;

        const coverFile = zip.file(coverPath);
        if (coverFile) {
            // Convert to base64 data URL for persistent storage
            const coverArrayBuffer = await coverFile.async('arraybuffer');
            const coverBlob = new Blob([coverArrayBuffer]);
            const mimeType = coverFile.name.endsWith('.png') ? 'image/png' :
                coverFile.name.endsWith('.gif') ? 'image/gif' :
                    'image/jpeg';

            // Convert blob to base64 data URL
            const base64 = await new Promise<string>((resolve, reject) => {
                const reader = new FileReader();
                reader.onloadend = () => resolve(reader.result as string);
                reader.onerror = reject;
                reader.readAsDataURL(new Blob([coverArrayBuffer], { type: mimeType }));
            });

            coverUrl = base64;
        }
    }

    return {
        title,
        author,
        coverUrl
    };
};
