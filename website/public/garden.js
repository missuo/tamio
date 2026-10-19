// Keep the static artwork when scripting or loading the scene is unavailable.
(() => {
  const landscapes = [...document.querySelectorAll(".landscape")];
  if (!landscapes.length) return;

  const prepareScene = (landscape, artwork) => {
    const fallback = landscape.querySelector("img");
    if (!fallback) return;

    const scene = document.importNode(artwork, true);
    scene.classList.add("garden-scene");
    scene.setAttribute("aria-hidden", "true");
    scene.setAttribute("focusable", "false");

    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    let visible = !("IntersectionObserver" in window);
    const update = () => {
      const paused = reducedMotion.matches || document.hidden || !visible;
      landscape.classList.toggle("is-paused", paused);
    };

    reducedMotion.addEventListener("change", update);
    document.addEventListener("visibilitychange", update);

    update();
    fallback.replaceWith(scene);
    landscape.classList.add("garden-ready");

    if ("IntersectionObserver" in window) {
      const observer = new IntersectionObserver(([entry]) => {
        visible = entry.isIntersecting;
        update();
      });
      observer.observe(landscape);
    }
  };

  fetch("/server-garden.svg")
    .then((response) => {
      if (!response.ok) throw new Error("Scene unavailable");
      return response.text();
    })
    .then((source) => {
      const parsed = new DOMParser().parseFromString(source, "image/svg+xml");
      const artwork = parsed.documentElement;
      if (parsed.querySelector("parsererror") || artwork.localName !== "svg"
        || artwork.namespaceURI !== "http://www.w3.org/2000/svg") {
        throw new Error("Invalid scene");
      }
      landscapes.forEach((landscape) => prepareScene(landscape, artwork));
    })
    .catch(() => { /* The image remains a complete, quiet version of the scene. */ });
})();
