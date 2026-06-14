import React, { useState } from 'react';

interface LanguageSwitcherProps {
  currentLang: string;
}

const languages = [
  { code: 'en', name: 'EN', flag: '🇬🇧' },
  { code: 'de', name: 'DE', flag: '🇩🇪' },
  { code: 'fr', name: 'FR', flag: '🇫🇷' },
  { code: 'es', name: 'ES', flag: '🇪🇸' }
];

export default function LanguageSwitcher({ currentLang }: LanguageSwitcherProps) {
  const [isOpen, setIsOpen] = useState(false);

  const handleLanguageChange = (code: string) => {
    if (code === currentLang) return;
    const currentPath = window.location.pathname;
    const pathWithoutLang = currentPath.replace(/^\/(en|de|fr|es)/, '') || '/';
    const cleanPath = pathWithoutLang.startsWith('/') ? pathWithoutLang : `/${pathWithoutLang}`;
    
    // Ensure clean path doesn't double slash
    const finalPath = cleanPath === '/' ? '' : cleanPath;
    window.location.href = `/${code}${finalPath}`;
  };

  const currentLanguageObj = languages.find(l => l.code === currentLang) || languages[0];

  return (
    <div className="lang-switcher-container">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="btn nav-cta-ask-ai lang-switcher-trigger"
      >
        <span>{currentLanguageObj.flag}</span>
        <span>{currentLanguageObj.name}</span>
        <svg 
          width="12" 
          height="12" 
          viewBox="0 0 24 24" 
          fill="none" 
          stroke="currentColor" 
          strokeWidth="2"
          className={`lang-switcher-arrow ${isOpen ? 'open' : ''}`}
        >
          <path d="M6 9l6 6 6-6" />
        </svg>
      </button>

      {isOpen && (
        <>
          <div 
            className="lang-switcher-overlay"
            onClick={() => setIsOpen(false)}
          />
          <div className="lang-switcher-dropdown">
            {languages.map((lang) => (
              <button
                key={lang.code}
                onClick={() => {
                  handleLanguageChange(lang.code);
                  setIsOpen(false);
                }}
                className={`lang-switcher-item ${lang.code === currentLang ? 'active' : ''}`}
              >
                <span>{lang.flag}</span>
                <span className={lang.code === currentLang ? 'body-sm-strong' : ''}>{lang.name}</span>
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
}
