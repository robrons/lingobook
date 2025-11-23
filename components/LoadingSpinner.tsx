import React from 'react';

export const LoadingSpinner: React.FC<{ message?: string, className?: string }> = ({ message, className = "" }) => (
  <div className={`flex flex-col items-center justify-center space-y-3 ${className}`}>
    <div className="w-6 h-6 border-2 border-stone-300 border-t-stone-600 rounded-full animate-spin"></div>
    {message && <span className="text-xs font-medium text-stone-500 uppercase tracking-wider">{message}</span>}
  </div>
);