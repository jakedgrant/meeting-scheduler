const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll(
    "/",
    "_",
  ).replace(/=+$/, "");
}

function decode(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("Invalid encrypted value");
  }
  const standard = value.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(
    atob(standard + "=".repeat((4 - standard.length % 4) % 4)),
    (c) => c.charCodeAt(0),
  );
}

export function randomSecret(): string {
  return base64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function sha256(value: string): Promise<string> {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(value)),
    ),
  )
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function pkceChallenge(verifier: string): Promise<string> {
  return base64url(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(verifier)),
    ),
  );
}

/** AES-256-GCM envelopes. The key ring lives only in Edge Function secrets.
 * Associated data binds ciphertext to its owner and purpose, preventing swaps.
 */
export class TokenCipher {
  private keys = new Map<string, CryptoKey>();
  private constructor(readonly activeKeyId: string) {}

  static async create(
    activeKeyId: string,
    encodedKeys: Record<string, string>,
  ): Promise<TokenCipher> {
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(activeKeyId)) {
      throw new Error("Invalid calendar key configuration");
    }
    const cipher = new TokenCipher(activeKeyId);
    for (const [id, encoded] of Object.entries(encodedKeys)) {
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(id) || typeof encoded !== "string") {
        throw new Error("Invalid calendar key configuration");
      }
      const bytes = decode(
        encoded.replace(/=+$/, "").replaceAll("+", "-").replaceAll("/", "_"),
      );
      if (bytes.length !== 32) {
        throw new Error("Calendar encryption keys must be 256 bits");
      }
      cipher.keys.set(
        id,
        await crypto.subtle.importKey("raw", bytes, "AES-GCM", false, [
          "encrypt",
          "decrypt",
        ]),
      );
    }
    if (!cipher.keys.has(activeKeyId)) {
      throw new Error("Active calendar key is missing");
    }
    return cipher;
  }

  async encrypt(value: string, purpose: string): Promise<string> {
    if (!value || value.length > 16000) {
      throw new Error("Invalid credential size");
    }
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv,
        additionalData: encoder.encode("calendar:v1:" + purpose),
      },
      this.keys.get(this.activeKeyId)!,
      encoder.encode(value),
    );
    return JSON.stringify({
      version: 1,
      key_id: this.activeKeyId,
      iv: base64url(iv),
      ciphertext: base64url(new Uint8Array(ciphertext)),
    });
  }

  async decrypt(value: string, purpose: string): Promise<string> {
    if (value.length > 24000) throw new Error("Invalid encrypted value");
    const envelope = JSON.parse(value);
    const key = this.keys.get(envelope.key_id);
    if (
      envelope.version !== 1 || !key || typeof envelope.iv !== "string" ||
      typeof envelope.ciphertext !== "string"
    ) throw new Error("Unknown calendar encryption envelope");
    const iv = decode(envelope.iv);
    if (iv.length !== 12) throw new Error("Invalid encrypted value");
    const plaintext = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv,
        additionalData: encoder.encode("calendar:v1:" + purpose),
      },
      key,
      decode(envelope.ciphertext),
    );
    return decoder.decode(plaintext);
  }
}
