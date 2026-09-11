"use strict";

const guideLinks = [...document.querySelectorAll(".wiki-sidebar a[href^='#']")];
const sections = guideLinks.map(link => document.querySelector(link.getAttribute("href"))).filter(Boolean);

if ("IntersectionObserver" in window) {
  const revealObserver = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-visible");
      revealObserver.unobserve(entry.target);
    });
  }, { rootMargin: "0px 0px -8%", threshold: .08 });
  sections.forEach(section => revealObserver.observe(section));

  const observer = new IntersectionObserver(entries => {
    const visible = entries.filter(entry => entry.isIntersecting).sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
    if (!visible) return;
    guideLinks.forEach(link => link.classList.toggle("is-current", link.getAttribute("href") === "#" + visible.target.id));
  }, { rootMargin: "-18% 0px -65%", threshold: [0, .25, .6] });
  sections.forEach(section => observer.observe(section));
} else {
  sections.forEach(section => section.classList.add("is-visible"));
}
