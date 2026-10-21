/* ==========================================================================
   Kopi — project website behaviour.
   Four small pieces: a mobile menu, a scroll reveal, a rotating pair of
   screenshots, and a gallery lightbox with keyboard navigation.
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

  /* -------------------------------------------------------------- carousel */
  /* Two screenshots of the application, one after the other. The rotation
     stops when the reader asks for less motion, when the tab is in the
     background, and when the reader presses the pause button. */
  (function carousel() {
    var root = document.querySelector('[data-carousel]');
    if (!root) return;

    var slides = Array.prototype.slice.call(root.querySelectorAll('[data-slide]'));
    var dots = Array.prototype.slice.call(root.querySelectorAll('[data-slide-dot]'));
    var caption = root.querySelector('[data-carousel-caption]');
    var pauseButton = root.querySelector('[data-carousel-pause]');
    if (slides.length < 2) return;

    var INTERVAL = 1000;
    var current = 0;
    var timer = null;
    var paused = false;
    var visible = true;

    function show(index) {
      current = (index + slides.length) % slides.length;
      slides.forEach(function (slide, position) {
        slide.classList.toggle('is-active', position === current);
      });
      dots.forEach(function (dot, position) {
        dot.classList.toggle('is-active', position === current);
        dot.setAttribute('aria-pressed', position === current ? 'true' : 'false');
      });
      if (caption) {
        caption.textContent = slides[current].getAttribute('data-caption') || '';
      }
    }

    function stop() {
      if (timer) { clearInterval(timer); timer = null; }
    }

    function start() {
      stop();
      if (paused || document.hidden || !visible) return;
      timer = setInterval(function () { show(current + 1); }, INTERVAL);
    }

    function setPaused(value) {
      paused = value;
      if (pauseButton) {
        pauseButton.classList.toggle('is-paused', paused);
        pauseButton.setAttribute('aria-label', paused
          ? 'Play the screenshot rotation'
          : 'Pause the screenshot rotation');
      }
      start();
    }

    dots.forEach(function (dot, index) {
      dot.addEventListener('click', function () {
        show(index);
        start();
      });
    });

    if (pauseButton) {
      pauseButton.addEventListener('click', function () { setPaused(!paused); });
    }

    document.addEventListener('visibilitychange', start);

    // Nothing turns while the pictures are off screen.
    if ('IntersectionObserver' in window) {
      var seen = new IntersectionObserver(function (entries) {
        visible = entries[0].isIntersecting;
        start();
      }, { threshold: 0.05 });
      seen.observe(root);
    }

    // A reader who asked for less motion keeps the first picture and chooses
    // the second one with the buttons.
    var reduceMotion = window.matchMedia
      && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduceMotion) {
      setPaused(true);
    } else {
      show(0);
      start();
    }
  })();

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
