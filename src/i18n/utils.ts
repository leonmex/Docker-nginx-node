import en from './locales/en.json';
import de from './locales/de.json';
import fr from './locales/fr.json';
import es from './locales/es.json';

const locales = { en, de, fr, es };

export type Locale = keyof typeof locales;

export function getTranslations(lang: string) {
  const currentLang = (lang in locales ? lang : 'en') as Locale;
  return locales[currentLang];
}

export function useTranslations(lang: string) {
  const translations = getTranslations(lang);
  return (key: keyof typeof en) => {
    return translations[key] || en[key] || key;
  };
}
