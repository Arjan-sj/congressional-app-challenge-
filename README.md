# SafeRoutes 🚸
### Making School Journeys Safer in Schaumburg, Illinois

SafeRoutes is a community-driven web application designed to help students, parents, and local officials identify potential walking and biking hazards around schools in Schaumburg, Illinois.

By combining community reports, interactive maps, and data-driven safety analysis, SafeRoutes aims to make school routes safer, more accessible, and easier to evaluate.

> **Project:** Congressional App Challenge  
> **Location:** Schaumburg, Illinois  
> **Platform:** Web application  
> **Status:** In development

---

## 📌 The Problem

Walking or biking to school should be a safe and accessible option for students. However, missing sidewalks, difficult intersections, blocked pathways, and other infrastructure problems can make certain routes challenging.

In September 2026, the Village of Schaumburg issued a request related to a Safe Routes to School safety audit and community travel plan covering sidewalk and bikeway connections to four elementary schools and two junior high schools.

This creates an opportunity to investigate local transportation safety needs and develop a tool that helps residents communicate concerns and understand potential hazards.

SafeRoutes aims to complement existing village transportation resources by focusing on school-specific safety reporting, route information, and analysis of community feedback.

## 💡 Our Solution

SafeRoutes provides a centralized platform where community members can report walking and biking hazards, explore reported issues on a map, and identify locations that may deserve further investigation.

Rather than relying on scattered reports or individual observations, the platform aims to organize community feedback into useful information for residents and local decision-makers.

## ✨ Planned Features

### 🗺️ Interactive Safety Map
- Display reported hazards around participating schools.
- Visualize reported locations using map markers and categories.
- Filter reports by hazard type, severity, and status.
- Explore available sidewalk and bikeway information from verified sources.

### 🚨 Community Hazard Reporting
Users will be able to submit reports for issues such as:

- Missing or damaged sidewalks
- Difficult or potentially unsafe intersections
- Blocked walking and biking paths
- Missing pedestrian crossings
- Poorly connected bicycle routes
- Other walking and biking accessibility concerns

Reports may include a location, category, description, and optional photograph.

### 📊 Data-Driven Risk Prioritization
SafeRoutes aims to identify recurring problem areas by analyzing:

- Number of reports at a location
- Reported severity
- Type of hazard
- Age and status of reports
- Proximity to participating schools

The resulting scores will help prioritize locations for further review. They will not represent official safety ratings or replace professional traffic engineering assessments.

### 🧭 Route Comparison
Where sufficient verified data is available, users will be able to compare potential walking and biking routes.

The application aims to highlight reported hazards and known infrastructure gaps, helping families make more informed decisions about their journeys.

SafeRoutes will not label a route completely safe simply because no hazards have been reported.

### 📈 Community Insights
- Summarize frequently reported hazard categories.
- Identify clusters of reports near schools.
- Display trends in reports over time.
- Help community members understand which issues are recurring.

### 🏫 School-Focused Information
Organize reports and map views around participating schools, allowing users to explore transportation concerns in the areas most relevant to their daily journeys.

## 🎯 Goals

1. Make it easier for students and families to report transportation safety concerns.
2. Improve visibility into walking and biking hazards near schools.
3. Identify recurring infrastructure problems through community feedback.
4. Encourage evidence-based discussions about school transportation safety.
5. Support community engagement with local transportation planning.

## 🛠️ Proposed Technology Stack

The final technology stack may change during development.

| Component | Proposed Technology |
|---|---|
| Frontend | HTML, CSS, JavaScript |
| Interactive maps | Leaflet |
| Map data | OpenStreetMap |
| Backend API | Python with Flask or FastAPI |
| Database | PostgreSQL with PostGIS, or SQLite for an initial prototype |
| Data analysis | Python |
| Version control | Git and GitHub |

### Architecture

The proposed application will use a web frontend to display map data and collect reports. A backend API will validate submissions, store reports, and provide aggregated information for the map and analytics dashboard.

Geographic database capabilities may be introduced as the project grows.

## 🔒 Privacy and Responsible Reporting

Because SafeRoutes concerns school communities and minors, privacy is a priority.

- Avoid collecting unnecessary personal information.
- Do not publicly display students' identities or contact details.
- Do not require users to disclose their home addresses.
- Review uploaded photographs to prevent the exposure of faces, license plates, and other identifying information.
- Validate reports and provide a way to flag inaccurate or inappropriate submissions.
- Clearly distinguish community-reported concerns from verified infrastructure information.

The application is intended to support community awareness, not to replace official reporting channels or emergency services.

## 🗺️ Development Roadmap

### Phase 1: Research and Planning
- [ ] Review Schaumburg's Safe Routes to School planning materials.
- [ ] Identify participating schools and relevant public map datasets.
- [ ] Survey students and parents about walking and biking concerns.
- [ ] Examine existing transportation reporting tools.

### Phase 2: Initial Website
- [ ] Create the website layout and navigation.
- [ ] Integrate an interactive map.
- [ ] Display sample hazard markers.
- [ ] Implement hazard categories and filters.

### Phase 3: Reporting System
- [ ] Build a hazard submission form.
- [ ] Add backend validation and database storage.
- [ ] Implement report status tracking.
- [ ] Add safeguards against spam and duplicate reports.

### Phase 4: Data Analysis
- [ ] Develop a transparent hazard prioritization algorithm.
- [ ] Visualize report concentrations around schools.
- [ ] Build a dashboard for community-level trends.
- [ ] Add route comparison using verified infrastructure data.

### Phase 5: Testing and Evaluation
- [ ] Test usability with community volunteers.
- [ ] Verify map accuracy and report handling.
- [ ] Compare findings with available public transportation assessments.
- [ ] Document limitations and opportunities for improvement.

## 📏 Measuring Success

SafeRoutes will evaluate its usefulness through measurable outcomes, including:

- Number of valid, actionable hazard reports
- Number of participating community members
- Percentage of reports successfully reviewed
- Time required to locate and submit a report
- Agreement between mapped information and verified observations
- User feedback on clarity and ease of use

These measurements will help determine whether the application provides useful information beyond existing resources.

## 🤝 Community Impact

SafeRoutes is intended to help students, families, and community stakeholders better understand transportation concerns around schools.

By organizing local observations into an accessible map and structured dataset, the project could support more informed conversations about pedestrian safety, bicycle accessibility, and infrastructure improvements.

The long-term goal is to demonstrate how technology can help communities identify problems, communicate their needs, and make better-informed decisions.

## 📚 Sources and Further Research

- [Village of Schaumburg Official Website](https://www.villageofschaumburg.com/)
- [Village of Schaumburg Transportation Resources](https://www.villageofschaumburg.com/government/transportation)
- [BusyBids](https://www.busybids.org/) — procurement information related to the reported September 2026 project
- [OpenStreetMap](https://www.openstreetmap.org/) — potential source of geographic data

Project-specific procurement documents, participating school names, and available infrastructure datasets should be verified before being incorporated into the application.

## 👨‍💻 Contributing

Contributions may include frontend development, map integration, backend development, data analysis, usability testing, and documentation.

Before contributing, open an issue to discuss the proposed change. Do not submit personal information about students or unverified allegations about individuals.

## 📄 License

A license has not yet been selected. A license should be added before the project is distributed for reuse.

---

**SafeRoutes — Better information for safer school journeys.**
