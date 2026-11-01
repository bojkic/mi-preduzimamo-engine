const normalized = (value) => value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase();

const initializeBoardAreaPickers = () => {
  document.querySelectorAll("[data-board-area-picker]").forEach((picker) => {
    if (picker.dataset.initialized) return;
    picker.dataset.initialized = "true";
    const search = picker.querySelector("[data-area-search]");
    const options = Array.from(picker.querySelectorAll("[data-area-option]"));
    const selected = picker.querySelector("[data-area-selected]");
    const count = picker.querySelector("[data-area-selection-count]");
    const update = () => {
      const query = normalized(search ? search.value.trim() : "");
      const checked = [];
      options.forEach((option) => {
        option.hidden = query.length > 0 && !normalized(option.dataset.areaName || "").includes(query);
        if (option.querySelector("input[type=checkbox]").checked) checked.push(option.dataset.areaName || "");
      });
      if (count) count.textContent = checked.length;
      if (selected) {
        selected.replaceChildren();
        checked.forEach((name) => {
          const chip = document.createElement("span");
          chip.textContent = name;
          selected.appendChild(chip);
        });
      }
    };
    if (search) search.addEventListener("input", update);
    picker.addEventListener("change", update);
    update();
  });
};
document.addEventListener("DOMContentLoaded", initializeBoardAreaPickers);
document.addEventListener("turbo:load", initializeBoardAreaPickers);
if (document.readyState !== "loading") initializeBoardAreaPickers();
