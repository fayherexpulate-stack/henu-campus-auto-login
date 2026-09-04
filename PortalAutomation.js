(cfg => {
  if (location.origin !== cfg.origin) return { ok: false, reason: 'unexpected-origin' };
  const user = document.querySelector('#userName');
  const pass = document.querySelector('#password');
  const login = document.querySelector('#loginBtn');
  const radio = document.querySelector('input[name="operator"][value="' + cfg.operator + '"]');
  const visible = el => el && el.getClientRects().length > 0;
  const events = window.jQuery && window.jQuery._data && login && window.jQuery._data(login, 'events');
  // Campus artwork can hang while the form already works. Require DOM + handlers, not every image.
  const ready = document.readyState !== 'loading' && visible(user) && visible(pass) && visible(login) &&
    radio && !login.disabled && events && events.click && events.click.length > 0;
  if (!ready) return { ok: false, reason: 'waiting-for-page-handlers', state: document.readyState,
    user:!!visible(user), pass:!!visible(pass), login:!!visible(login), radio:!!radio,
    jquery:!!window.jQuery, data:!!(window.jQuery && window.jQuery._data), events:!!events };
  if (cfg.action === 'ready') return { ok: true, ready: true };
  const set = (el, value) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  set(user, cfg.username);
  set(pass, cfg.password);
  // The portal toggles the provider OFF on a second click. Preserve selection.
  const provider = radio.closest('span');
  if (!provider || !provider.classList.contains('on')) radio.click();
  const selected = provider && provider.classList.contains('on');
  if (!selected || user.value !== cfg.username || pass.value !== cfg.password) {
    return { ok: false, reason: 'form-verification-failed' };
  }
  const remember = document.querySelector('#rememberPassword');
  if (remember && remember.checked) remember.click();
  // Click synchronously: report dispatch only after the handler was invoked.
  login.click();
  return { ok: true, submitted: true, provider: cfg.operator, filled: true };
})
