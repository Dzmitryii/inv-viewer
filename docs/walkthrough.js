"use strict";

const buttons = [...document.querySelectorAll("[data-frame]")];
const frame = document.getElementById("frame");
const caption = document.getElementById("caption");

function showStep(index) {
  const { frame: name, alt, caption: text } = buttons[index].dataset;
  frame.src = `assets/${name}.jpg`;
  frame.alt = alt;
  caption.textContent = text;
  buttons.forEach((button, i) => button.setAttribute("aria-pressed", String(index === i)));
}

buttons.forEach((button, index) => {
  button.addEventListener("click", () => showStep(index));
  button.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    const shift = event.key === "ArrowLeft" ? -1 : 1;
    const next = (index + shift + buttons.length) % buttons.length;
    showStep(next);
    buttons[next].focus();
  });
});
