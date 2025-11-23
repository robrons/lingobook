import React, { useCallback, useState, useEffect } from 'react';
import { BookOpen, Upload, Library as LibraryIcon, Trash2 } from 'lucide-react';
import { getAllBooks, deleteBook, BookRecord } from '../services/db';

interface LibraryProps {
  onBookLoaded: (bookId: number) => void;
  onBookUploaded: (file: File) => void;
}

export const Library: React.FC<LibraryProps> = ({ onBookLoaded, onBookUploaded }) => {
  const [isDragging, setIsDragging] = useState(false);
  const [books, setBooks] = useState<BookRecord[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    loadBooks();
  }, []);

  const loadBooks = async () => {
    try {
      const savedBooks = await getAllBooks();
      setBooks(savedBooks);
    } catch (error) {
      console.error('Failed to load books:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleFile = useCallback((file: File) => {
    // Check for valid EPUB mime type OR extension (case-insensitive)
    // Some browsers/OS combinations may fail to detect the correct MIME type for .epub
    const isMimeValid = file.type === "application/epub+zip";
    const isExtensionValid = file.name.toLowerCase().endsWith(".epub");

    if (!isMimeValid && !isExtensionValid) {
      alert("Please upload a valid EPUB file.");
      return;
    }

    onBookUploaded(file);
  }, [onBookUploaded]);

  const onDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
    if (e.dataTransfer.files && e.dataTransfer.files[0]) {
      handleFile(e.dataTransfer.files[0]);
    }
  }, [handleFile]);

  const onDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(true);
  }, []);

  const onDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
  }, []);

  const handleDeleteBook = async (e: React.MouseEvent, bookId: number) => {
    e.stopPropagation();
    if (confirm('Are you sure you want to delete this book?')) {
      try {
        await deleteBook(bookId);
        await loadBooks();
      } catch (error) {
        console.error('Failed to delete book:', error);
      }
    }
  };

  if (isLoading) {
    return (
      <div className="h-full w-full flex items-center justify-center bg-stone-50">
        <div className="animate-pulse flex flex-col items-center gap-4">
          <div className="w-12 h-12 bg-stone-200 rounded-full"></div>
          <div className="text-stone-400 text-sm">Loading library...</div>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full w-full flex flex-col items-center justify-start p-6 bg-stone-50 overflow-y-auto">
      <div className="max-w-5xl w-full space-y-8 text-center">

        <div className="space-y-4 pt-6">
          <div className="w-20 h-20 bg-orange-500 rounded-2xl mx-auto flex items-center justify-center shadow-lg shadow-orange-200">
            <BookOpen className="w-10 h-10 text-white" />
          </div>
          <h1 className="text-4xl font-serif-apple font-bold tracking-tight text-stone-900">
            LingoBook
          </h1>
          <p className="text-lg text-stone-500 max-w-md mx-auto">
            Read your favorite books in their native language, with AI-powered bilingual support just a tap away.
          </p>
        </div>

        <div
          onDrop={onDrop}
          onDragOver={onDragOver}
          onDragLeave={onDragLeave}
          className={`
            group relative border-2 border-dashed rounded-3xl p-8 transition-all duration-300 cursor-pointer
            flex flex-col items-center justify-center gap-4
            ${isDragging
              ? 'border-orange-500 bg-orange-50 scale-[1.02]'
              : 'border-stone-200 hover:border-stone-300 hover:bg-white bg-stone-100/50'
            }
          `}
        >
          <input
            type="file"
            className="absolute inset-0 w-full h-full opacity-0 cursor-pointer"
            accept=".epub"
            onChange={(e) => {
              if (e.target.files?.[0]) handleFile(e.target.files[0]);
            }}
          />

          <div className={`p-4 rounded-full transition-colors ${isDragging ? 'bg-orange-100' : 'bg-white shadow-sm group-hover:shadow-md'}`}>
            <Upload className={`w-8 h-8 ${isDragging ? 'text-orange-600' : 'text-stone-400'}`} />
          </div>

          <div className="space-y-1">
            <p className="font-medium text-stone-900">Tap to upload or drag and drop</p>
            <p className="text-sm text-stone-400">EPUB files only</p>
          </div>
        </div>

        {/* Book Library */}
        <div className="pt-4 w-full text-left">
          <h3 className="text-sm font-semibold text-stone-400 uppercase tracking-wider mb-4 flex items-center gap-2">
            <LibraryIcon className="w-4 h-4" />
            <span>{books.length === 0 ? 'Library Empty' : `Library (${books.length})`}</span>
          </h3>

          {books.length === 0 ? (
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4 opacity-40 grayscale select-none pointer-events-none">
              {[1, 2, 3, 4].map(i => (
                <div key={i} className="aspect-[2/3] bg-stone-200 rounded-lg shadow-inner relative overflow-hidden">
                  <div className="absolute inset-0 flex items-center justify-center">
                    <div className="w-12 h-12 border-4 border-stone-300 rounded-full"></div>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-5 gap-4">
              {books.map((book) => (
                <div
                  key={book.id}
                  onClick={() => book.id && onBookLoaded(book.id)}
                  className="group relative aspect-[2/3] bg-white rounded-lg shadow-md hover:shadow-xl transition-all duration-300 cursor-pointer overflow-hidden border border-stone-200"
                >
                  {book.coverUrl ? (
                    <img
                      src={book.coverUrl}
                      alt={book.title}
                      className="w-full h-full object-cover"
                    />
                  ) : (
                    <div className="w-full h-full bg-gradient-to-br from-orange-400 to-orange-600 flex items-center justify-center p-4">
                      <BookOpen className="w-12 h-12 text-white opacity-50" />
                    </div>
                  )}

                  {/* Overlay with book info */}
                  <div className="absolute inset-0 bg-gradient-to-t from-black/80 via-black/40 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-300 flex flex-col justify-end p-3">
                    <p className="text-white font-semibold text-sm line-clamp-2 mb-1">{book.title}</p>
                    <p className="text-white/80 text-xs line-clamp-1">{book.author}</p>

                    <button
                      onClick={(e) => book.id && handleDeleteBook(e, book.id)}
                      className="absolute top-2 right-2 p-2 bg-red-500 text-white rounded-full opacity-0 group-hover:opacity-100 transition-opacity hover:bg-red-600"
                      title="Delete book"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

      </div>
    </div>
  );
};