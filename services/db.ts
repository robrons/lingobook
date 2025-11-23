const DB_NAME = 'LingoBookDB';
const BOOKS_STORE = 'books';
const SETTINGS_STORE = 'settings';
const DB_VERSION = 4; // Incremented to force schema fix

// ... (imports and interfaces remain the same)

export interface BookRecord {
    id?: number;
    title: string;
    author: string;
    coverUrl?: string;
    data: ArrayBuffer;
    dateAdded: number;
    lastLocation?: string; // CFI string
}


export interface TranslationRecord {
    original: string;
    translated: string;
    language: string; // Target language
    timestamp: number;
}

const TRANSLATIONS_STORE = 'translations';

export const initDB = (): Promise<IDBDatabase> => {
    return new Promise((resolve, reject) => {
        const request = indexedDB.open(DB_NAME, DB_VERSION);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result);

        request.onupgradeneeded = (event) => {
            const db = (event.target as IDBOpenDBRequest).result;

            // Handle upgrade: Delete old incompatible store if upgrading from < 3
            // This ensures we get a fresh store with the correct keyPath and autoIncrement
            if (event.oldVersion < 3) {
                if (db.objectStoreNames.contains(BOOKS_STORE)) {
                    db.deleteObjectStore(BOOKS_STORE);
                }
            }

            // Create books store if it doesn't exist
            if (!db.objectStoreNames.contains(BOOKS_STORE)) {
                db.createObjectStore(BOOKS_STORE, { keyPath: 'id', autoIncrement: true });
            }

            // Create settings store if it doesn't exist
            if (!db.objectStoreNames.contains(SETTINGS_STORE)) {
                db.createObjectStore(SETTINGS_STORE);
            }

            // Create translations store if it doesn't exist
            if (!db.objectStoreNames.contains(TRANSLATIONS_STORE)) {
                // We'll use the original text as the key for simplicity, assuming one target language per original text usually
                // Or we can use a composite key if we supported multiple languages for the same text.
                // For now, let's just use 'original' as keyPath.
                // If we need to support multiple languages for same text, we might need a composite index or just append lang to key.
                // Let's use a composite key approach by just storing it and querying.
                // Actually, let's keep it simple: keyPath is 'original'. If we translate to a different language, we might overwrite.
                // But the app seems to default to English.
                // To be safe, let's not define a keyPath and use out-of-line keys, or use a composite string key.
                // Let's use 'original' as keyPath for now, it's the most common lookup.
                db.createObjectStore(TRANSLATIONS_STORE, { keyPath: 'original' });
            }
        };
    });
};

export const saveBook = async (record: Omit<BookRecord, 'id'>): Promise<number> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(BOOKS_STORE, 'readwrite');
        const store = transaction.objectStore(BOOKS_STORE);
        const request = store.add(record);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result as number);
    });
};

export const getAllBooks = async (): Promise<BookRecord[]> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(BOOKS_STORE, 'readonly');
        const store = transaction.objectStore(BOOKS_STORE);
        const request = store.getAll();

        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
            const books = request.result as BookRecord[];
            // Sort by dateAdded descending (newest first)
            books.sort((a, b) => b.dateAdded - a.dateAdded);
            resolve(books);
        };
    });
};

export const getBookById = async (id: number): Promise<BookRecord | null> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(BOOKS_STORE, 'readonly');
        const store = transaction.objectStore(BOOKS_STORE);
        const request = store.get(id);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result || null);
    });
};

export const deleteBook = async (id: number): Promise<void> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(BOOKS_STORE, 'readwrite');
        const store = transaction.objectStore(BOOKS_STORE);
        const request = store.delete(id);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
};

export const getCurrentBookId = async (): Promise<number | null> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(SETTINGS_STORE, 'readonly');
        const store = transaction.objectStore(SETTINGS_STORE);
        const request = store.get('currentBookId');

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result || null);
    });
};

export const setCurrentBookId = async (id: number | null): Promise<void> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(SETTINGS_STORE, 'readwrite');
        const store = transaction.objectStore(SETTINGS_STORE);
        const request = id === null
            ? store.delete('currentBookId')
            : store.put(id, 'currentBookId');

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
};

// Legacy function for migration - load old single-book storage
export const loadLegacyBook = async (): Promise<ArrayBuffer | null> => {
    try {
        const request = indexedDB.open('LingoBookDB', 1);
        const db = await new Promise<IDBDatabase>((resolve, reject) => {
            request.onerror = () => reject(request.error);
            request.onsuccess = () => resolve(request.result);
            request.onupgradeneeded = () => { }; // Ignore upgrades
        });

        if (!db.objectStoreNames.contains('books')) {
            return null;
        }

        const transaction = db.transaction('books', 'readonly');
        const store = transaction.objectStore('books');
        const getRequest = store.get('currentBook');

        return new Promise((resolve, reject) => {
            getRequest.onerror = () => resolve(null);
            getRequest.onsuccess = () => resolve(getRequest.result || null);
        });
    } catch {
        return null;
    }
};

// Migration function to fix existing books with blob URLs
export const migrateBookCovers = async (): Promise<void> => {
    try {
        const db = await initDB();
        const books = await getAllBooks();

        let migrated = 0;
        for (const book of books) {
            // Check if the cover URL is a blob URL (needs migration)
            if (book.coverUrl && book.coverUrl.startsWith('blob:')) {
                try {
                    // Re-extract metadata from the book data
                    const { extractMetadata } = await import('./epubMetadata');
                    const metadata = await extractMetadata(book.data);

                    // Update the book with the new base64 cover URL
                    if (metadata.coverUrl && book.id) {
                        const transaction = db.transaction(BOOKS_STORE, 'readwrite');
                        const store = transaction.objectStore(BOOKS_STORE);

                        const updatedBook = {
                            ...book,
                            coverUrl: metadata.coverUrl
                        };

                        await new Promise<void>((resolve, reject) => {
                            const request = store.put(updatedBook);
                            request.onerror = () => reject(request.error);
                            request.onsuccess = () => resolve();
                        });

                        migrated++;
                        console.log(`Migrated cover for book: ${book.title}`);
                    }
                } catch (error) {
                    console.error(`Failed to migrate cover for book ${book.title}:`, error);
                }
            }
        }

        if (migrated > 0) {
            console.log(`Successfully migrated ${migrated} book cover(s)`);
        }
    } catch (error) {
        console.error('Failed to run book cover migration:', error);
    }
};

export const updateBookProgress = async (id: number, location: string): Promise<void> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(BOOKS_STORE, 'readwrite');
        const store = transaction.objectStore(BOOKS_STORE);
        const getRequest = store.get(id);

        getRequest.onerror = () => reject(getRequest.error);
        getRequest.onsuccess = () => {
            const book = getRequest.result as BookRecord;
            if (!book) {
                reject(new Error(`Book with id ${id} not found`));
                return;
            }

            book.lastLocation = location;
            const updateRequest = store.put(book);

            updateRequest.onerror = () => reject(updateRequest.error);
            updateRequest.onsuccess = () => resolve();
        };
    });
};

export const saveTranslation = async (original: string, translated: string, language: string = 'English'): Promise<void> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(TRANSLATIONS_STORE, 'readwrite');
        const store = transaction.objectStore(TRANSLATIONS_STORE);
        const record: TranslationRecord = {
            original,
            translated,
            language,
            timestamp: Date.now()
        };
        const request = store.put(record);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
};

export const getTranslation = async (original: string): Promise<string | null> => {
    const db = await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction(TRANSLATIONS_STORE, 'readonly');
        const store = transaction.objectStore(TRANSLATIONS_STORE);
        const request = store.get(original);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
            const result = request.result as TranslationRecord;
            resolve(result ? result.translated : null);
        };
    });
};


