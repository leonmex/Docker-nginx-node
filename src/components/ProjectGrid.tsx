import React, { useState } from 'react';

interface Project {
  type: 'personal' | 'automation';
  name: string;
  description: string;
  url?: string;
  nodesCount?: number;
  nodes?: Array<{ name: string; type: string }>;
  connections?: any;
}

interface ProjectGridProps {
  personalProjects: Array<{ name: string; description: string; url?: string }>;
  n8nProjects: Array<{ name: string; nodes: Array<{ name: string; type: string }>; connections: any }>;
  translations: {
    all: string;
    personal: string;
    automation: string;
    viewWorkflow: string;
    nodesLabel: string;
  };
}

export default function ProjectGrid({ personalProjects, n8nProjects, translations }: ProjectGridProps) {
  const [filter, setFilter] = useState<'all' | 'personal' | 'automation'>('all');
  const [selectedWorkflow, setSelectedWorkflow] = useState<any | null>(null);

  // Map n8n workflows to standard project structure
  const mappedN8nProjects: Project[] = n8nProjects.map(proj => {
    // Generate description based on n8n terms
    const nodeTypes = proj.nodes.map(n => n.name).join(', ');
    const description = `n8n automated workflow triggered by a Webhook. Processes data using functions and conditional routers, executing actions across ${proj.nodes.length} nodes (includes: ${nodeTypes}).`;
    
    return {
      type: 'automation',
      name: proj.name,
      description,
      nodesCount: proj.nodes.length,
      nodes: proj.nodes,
      connections: proj.connections
    };
  });

  const mappedPersonalProjects: Project[] = personalProjects.map(proj => ({
    type: 'personal',
    name: proj.name,
    description: proj.description,
    url: proj.url
  }));

  const allProjects = [...mappedPersonalProjects, ...mappedN8nProjects];

  const filteredProjects = allProjects.filter(proj => {
    if (filter === 'all') return true;
    return proj.type === filter;
  });

  return (
    <div>
      {/* Filters */}
      <div className="project-filters-container">
        {(['all', 'personal', 'automation'] as const).map((type) => (
          <button
            key={type}
            onClick={() => setFilter(type)}
            className={`btn btn-secondary-sm project-filter-btn ${filter === type ? 'active' : ''}`}
          >
            {type === 'all' && translations.all}
            {type === 'personal' && translations.personal}
            {type === 'automation' && translations.automation}
          </button>
        ))}
      </div>

      {/* Grid */}
      <div className="grid-3">
        {filteredProjects.map((project, idx) => (
          <div 
            key={idx} 
            className="card-marketing project-card-wrapper"
          >
            <div>
              {/* Type Badge */}
              <div className="project-card-header">
                <span className={`caption-mono project-card-type-badge ${project.type}`}>
                  {project.type === 'automation' ? 'n8n workflow' : 'personal project'}
                </span>
                {project.type === 'automation' && (
                  <span className="badge-secondary project-card-nodes-count">
                    {project.nodesCount} {translations.nodesLabel}
                  </span>
                )}
              </div>

              {/* Title */}
              <h3 className="display-sm project-card-title">
                {project.name}
              </h3>

              {/* Description */}
              <p className="body-sm project-card-description">
                {project.description}
              </p>
            </div>

            {/* Actions */}
            <div>
              {project.type === 'personal' ? (
                project.url ? (
                  <a 
                    href={project.url} 
                    target="_blank" 
                    rel="noopener noreferrer"
                    className="btn btn-secondary-sm project-card-action-btn"
                  >
                    View Source (GitHub)
                  </a>
                ) : (
                  <span className="project-card-action-text">
                    Proprietary / Internal
                  </span>
                )
              ) : (
                <button 
                  onClick={() => setSelectedWorkflow(project)}
                  className="btn btn-primary-sm project-card-action-btn"
                >
                  {translations.viewWorkflow}
                </button>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* n8n Workflow Modal */}
      {selectedWorkflow && (
        <div 
          className="modal-overlay"
          onClick={() => setSelectedWorkflow(null)}
        >
          <div 
            className="card-marketing-large modal-content-card"
            onClick={(e) => e.stopPropagation()}
          >
            {/* Close */}
            <button 
              onClick={() => setSelectedWorkflow(null)}
              className="modal-close-btn"
            >
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <line x1="18" y1="6" x2="6" y2="18"></line>
                <line x1="6" y1="6" x2="18" y2="18"></line>
              </svg>
            </button>

            <span className="caption-mono modal-eyebrow">
              n8n automation pipeline
            </span>
            <h2 className="display-md modal-title">{selectedWorkflow.name}</h2>
            <p className="body-md modal-description">{selectedWorkflow.description}</p>

            {/* Visual Nodes representation */}
            <h4 className="caption-mono modal-section-title">Workflow Pipeline Visualizer</h4>
            <div className="modal-pipeline-visualizer">
              {selectedWorkflow.nodes?.map((node: any, nIdx: number) => (
                <React.Fragment key={nIdx}>
                  {nIdx > 0 && (
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" className="modal-pipeline-arrow">
                      <path d="M5 12h14M12 5l7 7-7 7" />
                    </svg>
                  )}
                  <div className="modal-pipeline-node-pill">
                    <span className={`modal-pipeline-node-indicator ${node.type.includes('webhook') ? 'webhook' : node.type.includes('function') ? 'function' : 'action'}`} />
                    <div className="modal-pipeline-node-info">
                      <span className="body-sm-strong modal-pipeline-node-name">{node.name}</span>
                      <span className="caption modal-pipeline-node-type">
                        {node.type.replace('n8n-nodes-base.', '')}
                      </span>
                    </div>
                  </div>
                </React.Fragment>
              ))}
            </div>

            {/* Raw JSON Config Mockup */}
            <h4 className="caption-mono modal-section-title">n8n Node JSON Schema</h4>
            <div className="code-editor-mockup">
              <pre className="modal-code-mockup">
                <code>
                  {JSON.stringify(selectedWorkflow.nodes, null, 2)}
                </code>
              </pre>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
