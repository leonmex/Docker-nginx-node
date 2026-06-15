## Project: Multilingual Personal Portfolio

You are an expert web developer. Build a complete, production-ready personal portfolio website using the following stack:

- **Astro** (latest v4.x)
- **React 19** (with client islands only where needed)
- **TypeScript** (latest v5.x, strict mode, compatible with Astro’s TS setup)
- **Docker** – the entire project runs inside a container named `webapp`
- **Node.js** (latest LTS) – all npm commands (install, dev, build) must be executed **inside** the `webapp` container

The design and layout should follow the structure and minimalistic style of **https://www.yanbraslavsky.com/** but adapted for my own personal brand. Use the design system defined in the `DESIGN.md` file located in the project root. Also respect any instructions inside `.agents/skills/vercel-skills/AGENTS.md` (Vercel best practices for React/Next.js – adapt them to Astro where applicable).

### 📄 Personal Content from a PDF
- All personal information (career timeline, work experience, education, skills, bio, etc.) must be extracted from a PDF file located at `.data/NoelBarreraGarcia-en_2026-4.doc.pdf`
- You do **not** need to parse the PDF manually. Instead, write a setup script (Node.js or bash) that:
  - Reads `.data/NoelBarreraGarcia-en_2026-4.doc.pdf`
  - Uses a simple PDF-to-text tool (e.g., `pdf-parse` library) to extract plain text
  - Converts the extracted content into structured JSON (e.g., `src/data/profile.json`)
  - This script should run automatically during `docker build` or as part of the initial setup
- The portfolio must reflect the real data from that PDF: job titles, dates, descriptions, education, etc.
- If the PDF is missing, the build should fail with a clear error message.

### 🌍 Multilingual Requirements
- **Supported languages:** English (default), German, French, Spanish.
- All user‑facing text must be translated into these four languages.
- Use **Astro’s i18n routing** (`/en/`, `/de/`, `/fr/`, `/es/`) with a root redirect to `/en/`.
- Store translations in JSON files (e.g., `src/i18n/locales/en.json`, etc.) and load them dynamically.
- Provide a language switcher in the header (flag icons or language names).

### 📁 Pages & Sections
Home

Purpose: Personal brand introduction and value proposition.

Sections
Hero Section
Name
Title (Engineering Leader / Head of Engineering)
Short positioning statement
CTA ("Book a Call", "Let's Connect")
Key Metrics
Years of experience
Team size managed
Products delivered
Industries worked in
Core Expertise
Engineering Leadership
Team Building
Technology Strategy
AI Adoption
Platform Engineering
Featured Companies
Testimonials
Contact CTA
2. About
Sections
Professional Bio
Leadership Philosophy
Career Journey
Education & Certifications
Personal Values
Leadership Principles
Languages
Personal Interests
3. Services
Sections
Fractional CTO / Head of Engineering
Technology leadership
Team scaling
Process improvement
Engineering Management Consulting
Org design
Hiring strategy
Performance frameworks
AI & Engineering Transformation
AI adoption
Developer productivity
Engineering workflows
Startup Advisory
Technical due diligence
Scaling strategy
Architecture reviews
Executive Mentoring
Engineering managers
New leaders
Career growth
4. Experience
Sections
Current Role
Previous Leadership Roles
Career Timeline
Key Achievements
Major Projects
Impact Metrics

Example:

Head of Engineering
AWS Leadership
E-Commerce Platforms
Mobile Development Leadership

Based on public profile information.

5. Case Studies
Sections
Scaling Engineering Organizations
Challenge
Approach
Results
Cost Optimization
Problem
Solution
Impact
AI Transformation
Adoption strategy
Outcomes
Platform Modernization
Architecture
Business value
6. Speaking & Community
Sections
Conference Talks
Podcasts
Workshops
Meetups Hosted
Event Gallery
Upcoming Events
7. Articles / Insights
Categories
Engineering Leadership
Team Management
AI in Software Development
Hiring & Culture
Architecture
Career Growth
Layout
Featured Article
Latest Articles
Newsletter Signup
8. Testimonials
Sections
Executive Testimonials
Peer Recommendations
Team Feedback
Client Success Stories
9. Resources
Sections
Leadership Frameworks
Hiring Templates
Team Health Checklists
Engineering Playbooks
Recommended Books
Downloads
10. Contact
Sections
Contact Form
Email
LinkedIn
Location
Calendar Booking
Social Links

All sections should be fully responsive, accessible, and follow the `DESIGN.md` guidelines (colors, typography, spacing).

### 🐳 Docker Requirements
- **Container name:** `webapp`
- **Base image:** `node:20-alpine` (or latest LTS)
- **Working directory:** `/app`
- **Port exposure:** 4321 (Astro default)
- **Volume mount:** The project root is mounted into `/app` so that code changes are reflected live (for development).
- **Commands:** All `npm`, `npx`, and `astro` commands must be run inside the container, never on the host.
- Provide a `docker-compose.yml` (or `compose.yaml`) with the `webapp` service.
- The Docker setup must support both **development** (with hot reload) and **production** (multi-stage build for a small image).

### 🔧 Technical Constraints
- **Astro islands:** Use React 19 components only when interactivity is needed (e.g., language switcher, contact form, dynamic project filter). Prefer Astro components for static content.
- **TypeScript:** No `any`. Define interfaces for projects, translations, profile data, etc.
- **n8n projects:** In the projects grid, highlight at least 3 example n8n automations (e.g., “GitHub → Discord notifications”, “Form to Airtable + Slack”, “RSS to Telegram bot”). Store these in a data file (e.g., `src/data/n8n-projects.json`).
- **SEO:** Generate correct hreflang meta tags, canonical URLs per language, and a sitemap.

### 📄 Files you must read before starting
1. `DESIGN.md` (project root) – use it as the single source of truth for UI styling.
2. `.agents/skills/vercel-skills/AGENTS.md` – apply any relevant performance, accessibility, or React patterns (but adapt to Astro’s partial hydration).

### ✅ Output Expectations
- Provide the full file tree and all source code.
- Include a `Dockerfile`, `docker-compose.yml`, and the PDF extraction script.
- Write a `README.md` that explains how to:
  - Place the PDF at `.data/personal-info.pdf`
  - Build and run the container: `docker compose up --build`
  - Access the site at `http://localhost:4321`
  - Run npm commands inside the container if needed (e.g., `docker compose exec webapp npm install <package>`)
- The final site must be buildable inside the container (`docker compose run webapp npm run build`) and run without errors.

### 👥 Recommendations Section
- **Interactivity**: Built with a React client-side island showing peer reviews.
- **Desktop Grid Layout**: Displays recommendations in 3 columns per row, showing up to 2 rows at a time (total 6 recommendations per page).
- **Mobile Responsive Layout**: On screens below 768px (mobile PWA mode), it displays only 2 recommendations per page (1 column x 2 rows) to keep screen estate clean.
- **Controls**: Includes paginated controls (Next and Previous buttons) with disabled states when at the first or last page.
- **Transitions**: Smooth page change sliding/fading animation effects.
- **Data Source**: Uses data loaded from `src/data/recommendations.json`.
- **LinkedIn Integration**: The `linkedinProfile` from the JSON file must be rendered as an `<a>` element wrapping the author's name (`{rec.name}`).

Start by explaining your plan, then generate the code.