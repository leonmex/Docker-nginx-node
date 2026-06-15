import React, { useState, useEffect } from 'react';

interface Recommendation {
  name: string;
  role: string;
  recommendation: string;
  linkedinProfile?: string;
}

interface RecommendationsGridProps {
  recommendations: Recommendation[];
  translations: {
    next: string;
    previous: string;
  };
}

export default function RecommendationsGrid({ recommendations, translations }: RecommendationsGridProps) {
  const [currentPage, setCurrentPage] = useState(0);
  const [itemsPerPage, setItemsPerPage] = useState(6);

  useEffect(() => {
    const handleResize = () => {
      if (window.innerWidth < 768) {
        setItemsPerPage(2);
      } else {
        setItemsPerPage(6);
      }
    };

    handleResize(); // Initialize on mount
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  // Reset page if itemsPerPage changes and index gets out of bounds
  const totalPages = Math.ceil(recommendations.length / itemsPerPage);
  
  useEffect(() => {
    if (currentPage >= totalPages) {
      setCurrentPage(Math.max(0, totalPages - 1));
    }
  }, [itemsPerPage, totalPages, currentPage]);

  const startIndex = currentPage * itemsPerPage;
  const currentRecommendations = recommendations.slice(startIndex, startIndex + itemsPerPage);

  const handleNext = () => {
    if (currentPage < totalPages - 1) {
      setCurrentPage(prev => prev + 1);
    }
  };

  const handlePrevious = () => {
    if (currentPage > 0) {
      setCurrentPage(prev => prev - 1);
    }
  };

  return (
    <div className="recommendations-wrapper">
      {/* Paginated Grid - changing the key triggers the CSS page turn entrance animation */}
      <div 
        key={currentPage} 
        className="grid-3 recommendations-page-transition"
      >
        {currentRecommendations.map((rec, idx) => (
          <div key={idx} className="card-marketing recommendation-card">
            <div className="recommendation-content">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="var(--colors-violet)" strokeWidth="2" className="recommendation-quote-icon">
                <path d="M3 21c3 0 7-1 7-8V5c0-1.1-.9-2-2-2H4c-1.1 0-2 .9-2 2v6c0 1.1.9 2 2 2h4c0 3.5-2.5 5.5-5 6v2zm11 0c3 0 7-1 7-8V5c0-1.1-.9-2-2-2h-4c-1.1 0-2 .9-2 2v6c0 1.1.9 2 2 2h4c0 3.5-2.5 5.5-5 6v2z" />
              </svg>
              <p className="body-sm recommendation-text">
                {rec.recommendation}
              </p>
            </div>
            <div className="recommendation-author-row">
              <h4 className="body-md-strong recommendation-author-name">
                {rec.linkedinProfile ? (
                  <a 
                    href={rec.linkedinProfile} 
                    target="_blank" 
                    rel="noopener noreferrer"
                    className="recommendation-linkedin-link"
                  >
                    {rec.name}
                  </a>
                ) : (
                  rec.name
                )}
              </h4>
              <p className="caption recommendation-author-role">
                {rec.role}
              </p>
            </div>
          </div>
        ))}
      </div>

      {/* Pagination Controls */}
      {totalPages > 1 && (
        <div className="recommendations-pagination-row">
          <button 
            onClick={handlePrevious} 
            disabled={currentPage === 0}
            className="btn btn-secondary-sm"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ marginRight: '6px' }}>
              <path d="M15 18l-6-6 6-6" />
            </svg>
            {translations.previous}
          </button>
          
          <span className="caption-mono recommendations-page-indicator">
            {currentPage + 1} / {totalPages}
          </span>

          <button 
            onClick={handleNext} 
            disabled={currentPage === totalPages - 1}
            className="btn btn-secondary-sm"
          >
            {translations.next}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ marginLeft: '6px' }}>
              <path d="M9 18l6-6-6-6" />
            </svg>
          </button>
        </div>
      )}
    </div>
  );
}
