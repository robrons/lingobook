export enum Theme {
  LIGHT = 'LIGHT',
  SEPIA = 'SEPIA',
  DARK = 'DARK',
}

export interface TranslationSegment {
  original: string;
  translated: string;
}

export interface BookMetadata {
  title: string;
  author: string;
  coverUrl?: string;
}

export interface TocItem {
  id: string;
  label: string;
  href: string;
}

// Minimal type definition for the global ePub object provided by the CDN script
export interface GlobalEpub {
  (data: ArrayBuffer | string): BookInstance;
}

export interface BookInstance {
  ready: Promise<void>;
  loaded: {
    metadata: Promise<BookMetadata>;
    navigation: Promise<any>;
    spine: Promise<any>;
    cover: Promise<string>;
  };
  spine: {
    get: (target: string) => SpineItem;
    each: (callback: (item: SpineItem) => void) => void;
  };
  renderTo: (elementId: string, options: any) => Rendition;
  destroy: () => void;
}

export interface SpineItem {
  href: string;
  index: number;
  id: string;
  load: (loader: any) => Promise<string | Document>; // Load returns the HTML content
  url: string;
}

export interface Rendition {
  display: (target?: string) => Promise<void>;
  next: () => Promise<void>;
  prev: () => Promise<void>;
  currentLocation: () => {
    start: { cfi: string; href: string; index: number };
    end: { cfi: string; href: string; index: number };
  };
  themes: {
    fontSize: (size: string) => void;
    font: (font: string) => void;
    register: (name: string, url: string | object) => void;
    select: (name: string) => void;
  };
  on: (event: string, callback: any) => void;
  destroy: () => void;
}

declare global {
  interface Window {
    ePub: GlobalEpub;
  }
}