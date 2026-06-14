import React, { useState } from 'react';

interface ContactFormProps {
  translations: {
    name: string;
    email: string;
    message: string;
    submit: string;
    success: string;
    reset: string;
  };
}

export default function ContactForm({ translations }: ContactFormProps) {
  const [formData, setFormData] = useState({ name: '', email: '', message: '' });
  const [isSubmitted, setIsSubmitted] = useState(false);
  const [error, setError] = useState('');

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
    setFormData({ ...formData, [e.target.name]: e.target.value });
    if (error) setError('');
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.name || !formData.email || !formData.message) {
      setError('Please fill in all fields.');
      return;
    }

    // Simulate form submission
    setIsSubmitted(true);
    setFormData({ name: '', email: '', message: '' });
  };

  if (isSubmitted) {
    return (
      <div className="contact-form-success-card">
        <svg 
          width="40" 
          height="40" 
          viewBox="0 0 24 24" 
          fill="none" 
          stroke="var(--colors-success)" 
          strokeWidth="2"
          className="contact-form-success-icon"
        >
          <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14" />
          <polyline points="22 4 12 14.01 9 11.01" />
        </svg>
        <p className="body-md-strong">
          {translations.success}
        </p>
        <button 
          onClick={() => setIsSubmitted(false)}
          className="btn btn-secondary-sm contact-form-success-btn"
        >
          {translations.reset}
        </button>
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="contact-form-container">
      {error && (
        <div className="contact-form-alert-error">
          {error}
        </div>
      )}
      
      <div>
        <label htmlFor="name" className="body-sm-strong contact-form-label">
          {translations.name}
        </label>
        <input
          type="text"
          id="name"
          name="name"
          value={formData.name}
          onChange={handleChange}
          className="form-input"
          placeholder="John Doe"
          required
        />
      </div>

      <div>
        <label htmlFor="email" className="body-sm-strong contact-form-label">
          {translations.email}
        </label>
        <input
          type="email"
          id="email"
          name="email"
          value={formData.email}
          onChange={handleChange}
          className="form-input"
          placeholder="john@example.com"
          required
        />
      </div>

      <div>
        <label htmlFor="message" className="body-sm-strong contact-form-label">
          {translations.message}
        </label>
        <textarea
          id="message"
          name="message"
          value={formData.message}
          onChange={handleChange}
          className="form-textarea"
          placeholder="How can I help you?"
          required
        />
      </div>

      <button type="submit" className="btn btn-primary contact-form-submit-btn">
        {translations.submit}
      </button>
    </form>
  );
}
