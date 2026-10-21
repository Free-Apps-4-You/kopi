/* ==========================================================================
   Kopi — project website behaviour.
   Three small pieces: a mobile menu, a scroll reveal, and a gallery
   lightbox with keyboard navigation.
   ========================================================================== */
(function () {
  'use strict';

  /* ------------------------------------------------------------- mobile menu */
  var nav = document.querySelector('.nav');
  var links = document.getElementById('nav-links');
  var toggle = document.querySelector('.nav__toggle');

  function closeMenu() {
    if (links) links.classList.remove('is-open');
    if (toggle) toggle.setAttribute('aria-expanded', 'false');
  }

  if (toggle && links) {
    toggle.addEventListener('click', function () {
      var open = links.classList.toggle('is-open');
      toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
    links.addEventListener('click', function (event) {
      if (event.target.tagName === 'A') closeMenu();
    });
  }

  /* --------------------------------------------------------- sticky border */
  if (nav) {
    var onScroll = function () {
      nav.classList.toggle('is-stuck', window.scrollY > 8);
    };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  /* ----------------------------------------------------------- scroll reveal */
  var revealed = document.querySelectorAll('[data-reveal]');
  if (!('IntersectionObserver' in window)) {
    revealed.forEach(function (node) { node.classList.add('is-visible'); });
  } else {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    revealed.forEach(function (node) { observer.observe(node); });
  }

  /* --------------------------------------------------------------- lightbox */
  var lightbox = document.getElementById('lightbox');
  var lightboxImage = document.getElementById('lightbox-img');
  var lightboxCaption = document.getElementById('lightbox-caption');
  var triggers = Array.prototype.slice.call(document.querySelectorAll('.shot__btn'));
  var slides = triggers.map(function (button) {
    var figure = button.closest('figure');
    var image = button.querySelector('img');
    return {
      src: image.getAttribute('src'),
      alt: image.getAttribute('alt') || '',
      caption: (figure && figure.getAttribute('data-caption')) || ''
    };
  });
  var current = 0;
  var lastFocused = null;

  function show(index) {
    if (!slides.length) return;
    current = (index + slides.length) % slides.length;
    var slide = slides[current];
    lightboxImage.setAttribute('src', slide.src);
    lightboxImage.setAttribute('alt', slide.alt);
    lightboxCaption.textContent = slide.caption;
    lightbox.hidden = false;
    document.body.classList.add('is-locked');
    var close = lightbox.querySelector('.lightbox__close');
    if (close) close.focus();
  }

  function hide() {
    lightbox.hidden = true;
    document.body.classList.remove('is-locked');
    if (lastFocused) lastFocused.focus();
  }

  triggers.forEach(function (button, index) {
    button.addEventListener('click', function () {
      lastFocused = button;
      show(index);
    });
  });

  if (lightbox) {
    lightbox.querySelector('.lightbox__close').addEventListener('click', hide);
    lightbox.querySelector('.lightbox__nav--prev').addEventListener('click', function () { show(current - 1); });
    lightbox.querySelector('.lightbox__nav--next').addEventListener('click', function () { show(current + 1); });
    lightbox.addEventListener('click', function (event) {
      if (event.target === lightbox) hide();
    });
  }

  document.addEventListener('keydown', function (event) {
    if (!lightbox || lightbox.hidden) return;
    if (event.key === 'Escape') { hide(); }
    else if (event.key === 'ArrowLeft') { show(current - 1); }
    else if (event.key === 'ArrowRight') { show(current + 1); }
  });
})();
