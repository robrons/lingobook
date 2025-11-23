import React, { useState, useEffect } from 'react';
import { Library } from './components/Library';
import { Reader } from './components/Reader';
import { saveBook, getBookById, setCurrentBookId, getCurrentBookId, migrateBookCovers } from './services/db';
import { extractMetadata } from './services/epubMetadata';

const App: React.FC = () => {
  const [currentBook, setCurrentBook] = useState<ArrayBuffer | null>(null);
  const [currentBookId, setCurrentBookIdState] = useState<number | null>(null);
  const [initialLocation, setInitialLocation] = useState<string | undefined>(undefined);
  const [isLoading, setIsLoading] = useState(true);

  // Load the currently selected book on startup
  useEffect(() => {
    const init = async () => {
      try {
        // Run migration to fix any books with blob URL covers
        await migrateBookCovers();

        const bookId = await getCurrentBookId();
        if (bookId !== null) {
          const book = await getBookById(bookId);
          if (book) {
            setCurrentBook(book.data);
            setCurrentBookIdState(bookId);
            setInitialLocation(book.lastLocation);
          }
        }
      } catch (error) {
        console.error('Failed to load current book:', error);
      } finally {
        setIsLoading(false);
      }
    };
    init();
  }, []);

  // When a book is selected from the library list
  const handleBookLoaded = async (bookId: number) => {
    try {
      const book = await getBookById(bookId);
      if (book) {
        setCurrentBook(book.data);
        setCurrentBookIdState(bookId);
        setInitialLocation(book.lastLocation);
        await setCurrentBookId(bookId);
      }
    } catch (error) {
      console.error('Failed to load selected book:', error);
    }
  };

  // When a new EPUB file is uploaded via the Library component
  const handleBookUploaded = async (file: File) => {
    try {
      const arrayBuffer = await file.arrayBuffer();
      const metadata = await extractMetadata(arrayBuffer);
      const record = {
        title: metadata.title,
        author: metadata.author,
        coverUrl: metadata.coverUrl,
        data: arrayBuffer,
        dateAdded: Date.now(),
      };
      const id = await saveBook(record);
      await setCurrentBookId(id);
      setCurrentBookIdState(id);
      setInitialLocation(undefined); // New book starts at beginning
      setCurrentBook(arrayBuffer);
    } catch (error) {
      console.error('Failed to process uploaded book:', error);
      const message = error instanceof Error ? error.message : 'Unknown error';
      alert(`Failed to load the EPUB file. Error: ${message}`);
    }
  };

  const handleBackToLibrary = async () => {
    setCurrentBook(null);
    setCurrentBookIdState(null);
    setInitialLocation(undefined);
    try {
      await setCurrentBookId(null);
    } catch (error) {
      console.error('Failed to clear current book ID:', error);
    }
  };

  if (isLoading) {
    return (
      <div className="w-full h-full flex items-center justify-center bg-stone-50">
        <div className="animate-pulse flex flex-col items-center gap-4">
          <div className="w-12 h-12 bg-stone-200 rounded-full"></div>
          <div className="text-stone-400 text-sm">Loading library...</div>
        </div>
      </div>
    );
  }

  return (
    <div className="w-full h-full relative">
      {currentBook && currentBookId !== null ? (
        <Reader
          bookData={currentBook}
          bookId={currentBookId}
          initialLocation={initialLocation}
          onBack={handleBackToLibrary}
        />
      ) : (
        <Library onBookLoaded={handleBookLoaded} onBookUploaded={handleBookUploaded} />
      )}
    </div>
  );
};

export default App;