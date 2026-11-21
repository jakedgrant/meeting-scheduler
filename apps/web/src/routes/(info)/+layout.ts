// The about and privacy pages are plain documents: render them on the server and
// ship no client JavaScript, so they never wait on sign-in. The alpha gate lets
// visitors without the password reach them (see OPEN_PATHS in the alpha gate).
export const csr = false
