# LingoBook

LingoBook is an intelligent, privacy-focused e-reader designed to help you learn languages while reading your favorite books. It runs entirely in your browser using local AI models (WebLLM) to provide real-time translation, summarization, and interactive reading modes—all without sending your data to the cloud.

## Features

- **📖 Local AI Processing**: Powered by [WebLLM](https://webllm.mlc.ai/), all translations and summaries happen locally on your device using WebGPU. No external API keys required for core features.
- **📚 Smart Reading Modes**:
  - **Original**: Enjoy a distraction-free reading experience.
  - **Split View**: Read the original text side-by-side with the translation.
  - **Interleaved**: View paragraph-by-paragraph translations for seamless context.
  - **Lines**: Break down text line-by-line for intensive language study.
- **💾 Interactive Library**: Upload and manage your EPUB collection. Your books and progress are saved automatically using IndexedDB.
- **🤖 Model Selection**: Choose from a curated list of high-performance local LLMs (including Llama 3, Mistral, Gemma, and Qwen) to balance speed and translation quality based on your device's capabilities.
- **🎨 Customizable Experience**: Toggle between Light, Dark, and Sepia themes, adjust font sizes, and enjoy a responsive, modern UI.

## Getting Started

### Prerequisites

- **Node.js** (v18 or higher recommended)
- A modern web browser with **WebGPU** support (e.g., Google Chrome 113+, Microsoft Edge, Arc).

### Installation

1.  **Clone the repository:**
    ```bash
    git clone <your-repo-url>
    cd lingobook
    ```

2.  **Install dependencies:**
    ```bash
    npm install
    ```

3.  **Start the development server:**
    ```bash
    npm run dev
    ```

4.  **Open the app:**
    Visit `http://localhost:3000` (or the URL provided in your terminal) to start using LingoBook.

## Usage

1.  **Upload a Book**: Drag and drop or select an EPUB file to add it to your library.
2.  **Select a Model**: In the reader view, use the dropdown menu to select and load a translation model. *Note: The first time you select a model, it will download to your browser cache (this may take a few minutes depending on your internet speed).*
3.  **Translate**: Switch to "Split", "Interleaved", or "Lines" mode to see the AI in action. The app will translate the current page or segment on-demand.

## Technologies

- **Frontend**: [React](https://react.dev/), [Vite](https://vitejs.dev/), [TypeScript](https://www.typescriptlang.org/)
- **AI Engine**: [WebLLM](https://github.com/mlc-ai/web-llm) (In-browser LLM inference)
- **E-book Engine**: [epub.js](https://github.com/futurepress/epub.js)
- **Styling**: [Tailwind CSS](https://tailwindcss.com/)
- **Icons**: [Lucide React](https://lucide.dev/)
- **Storage**: IndexedDB (via local helper)

## License

MIT
