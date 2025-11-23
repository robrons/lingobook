
const { JSDOM } = require("jsdom");

const getText = (node: any): string => {
    if (node.nodeType === 3) { // TEXT_NODE
        return node.nodeValue || "";
    }
    if (node.nodeType === 1) { // ELEMENT_NODE
        const el = node;
        const tagName = el.tagName.toLowerCase();

        // Skip invisible/technical tags
        if (['script', 'style', 'noscript', 'meta', 'link', 'object', 'embed'].includes(tagName)) return "";

        let content = "";
        const children = Array.from(node.childNodes);
        for (const child of children) {
            content += getText(child);
        }

        // Add spacing for block elements to preserve paragraph structure
        if (['p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'tr', 'article', 'section', 'blockquote'].includes(tagName)) {
            return "\n" + content + "\n";
        }
        if (tagName === 'br') return "\n";

        return content;
    }
    return "";
};

const extractContentFromDoc = (docString: string) => {
    const dom = new JSDOM(docString);
    const doc = dom.window.document;
    const body = doc.body || doc.documentElement;

    let raw = getText(body);
    // Collapse multiple newlines to max 2 to preserve paragraph breaks but remove huge gaps
    raw = raw.replace(/\n\s*\n\s*\n/g, '\n\n').trim();

    return raw;
};

const sampleHtml = `
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>Test Chapter</title>
</head>
<body>
    <h1>Chapter 1</h1>
    <p>This is the first paragraph.</p>
    <div>
        <p>This is a nested paragraph.</p>
    </div>
    <p>This is the last paragraph.</p>
</body>
</html>
`;

console.log("--- Extracted Text ---");
console.log(extractContentFromDoc(sampleHtml));
console.log("----------------------");
