import "../src/decidim/bih/komsiluk_admin";

const enhanceResponsiveTables = (root = document) => {
  root.querySelectorAll("[data-mi-admin-surface] .table-stacked table").forEach((table) => {
    const labels = Array.from(table.querySelectorAll("thead th"), (header) => header.textContent.trim());

    table.querySelectorAll("tbody tr").forEach((row) => {
      Array.from(row.children).forEach((cell, index) => {
        if (cell.tagName === "TD" && !cell.dataset.label && labels[index]) {
          cell.dataset.label = labels[index];
        }
      });
    });
  });
};

const initializeAdminSurface = () => enhanceResponsiveTables();

document.addEventListener("DOMContentLoaded", initializeAdminSurface);
document.addEventListener("turbo:load", initializeAdminSurface);

if (document.readyState !== "loading") {
  initializeAdminSurface();
}
