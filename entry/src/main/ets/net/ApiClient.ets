/**
 * HTTP 接口客户端。
 *
 * 所有请求都走这里，统一处理鉴权头、超时和错误转换。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  ProjectInfo,
  SessionInfo,
  PairResponse,
  PingResponse,
  WireEvent
} from './Protocol';

const CONNECT_TIMEOUT = 8000;
const READ_TIMEOUT = 20000;

/** 业务错误：带上 HTTP 状态码，方便上层区分「没配对」和「网络不通」 */
export class ApiException extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }

  /** token 失效或未配对 */
  isUnauthorized(): boolean {
    return this.status === 401;
  }

  /** 压根没连上服务器 */
  isNetworkError(): boolean {
    return this.status === 0;
  }
}

interface ErrorBody {
  error?: string;
}

/**
 * 配对请求体。
 * ArkTS 不允许无类型的对象字面量（arkts-no-untyped-obj-literals），
 * `as Record<string, string>` 也不算数，必须有显式声明的接口。
 */
interface PairRequest {
  code: string;
  deviceName: string;
}

export class ApiClient {
  private host: string = '';
  private port: number = 4517;
  private token: string = '';

  configure(host: string, port: number, token: string): void {
    this.host = host;
    this.port = port;
    this.token = token;
  }

  baseUrl(): string {
    return `http://${this.host}:${this.port}`;
  }

  /** WebSocket 地址，供 WsClient 使用 */
  wsUrl(): string {
    return `ws://${this.host}:${this.port}/ws`;
  }

  getToken(): string {
    return this.token;
  }

  // -------------------------------------------------------------------------
  // 底层请求
  // -------------------------------------------------------------------------

  private async request(
    path: string,
    method: http.RequestMethod,
    body?: string,
    withAuth: boolean = true
  ): Promise<string> {
    const req = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json'
      };
      if (withAuth && this.token.length > 0) {
        header['Authorization'] = `Bearer ${this.token}`;
      }

      const options: http.HttpRequestOptions = {
        method: method,
        header: header,
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: READ_TIMEOUT
      };
      if (body !== undefined) {
        options.extraData = body;
      }

      const res = await req.request(`${this.baseUrl()}${path}`, options);
      const text = res.result as string;

      if (res.responseCode >= 200 && res.responseCode < 300) {
        return text;
      }

      // 服务端的错误体是 {"error":"..."}，取出来给用户看
      let message = `请求失败 (${res.responseCode})`;
      try {
        const parsed = JSON.parse(text) as ErrorBody;
        if (parsed.error !== undefined && parsed.error.length > 0) {
          message = parsed.error;
        }
      } catch (_e) {
        // 错误体不是 JSON，用默认文案
      }
      throw new ApiException(res.responseCode, message);
    } catch (e) {
      if (e instanceof ApiException) {
        throw e;
      }
      // 连接层面的失败，status 用 0 表示「没到服务器」
      const err = e as BusinessError;
      throw new ApiException(0, `无法连接服务器：${err.message ?? '未知错误'}`);
    } finally {
      req.destroy();
    }
  }

  // -------------------------------------------------------------------------
  // 业务接口
  // -------------------------------------------------------------------------

  /** 探测服务器是否可达。配对页用它先校验地址，再让用户输配对码 */
  async ping(host: string, port: number): Promise<PingResponse> {
    const saved = this.host;
    const savedPort = this.port;
    this.host = host;
    this.port = port;
    try {
      const text = await this.request('/api/ping', http.RequestMethod.GET, undefined, false);
      return JSON.parse(text) as PingResponse;
    } finally {
      this.host = saved;
      this.port = savedPort;
    }
  }

  /** 用配对码换长期 token */
  async pair(
    host: string,
    port: number,
    code: string,
    deviceName: string
  ): Promise<PairResponse> {
    const saved = this.host;
    const savedPort = this.port;
    this.host = host;
    this.port = port;
    try {
      const payload: PairRequest = { code: code, deviceName: deviceName };
      const body = JSON.stringify(payload);
      const text = await this.request('/api/pair', http.RequestMethod.POST, body, false);
      return JSON.parse(text) as PairResponse;
    } finally {
      this.host = saved;
      this.port = savedPort;
    }
  }

  async listProjects(): Promise<ProjectInfo[]> {
    const text = await this.request('/api/projects', http.RequestMethod.GET);
    return JSON.parse(text) as ProjectInfo[];
  }

  async listSessions(projectId: string): Promise<SessionInfo[]> {
    const path = `/api/projects/${encodeURIComponent(projectId)}/sessions`;
    const text = await this.request(path, http.RequestMethod.GET);
    return JSON.parse(text) as SessionInfo[];
  }

  async loadHistory(sessionId: string, limit: number = 200): Promise<WireEvent[]> {
    const path = `/api/sessions/${encodeURIComponent(sessionId)}/messages?limit=${limit}`;
    const text = await this.request(path, http.RequestMethod.GET);
    return JSON.parse(text) as WireEvent[];
  }
}

/** 全局单例 */
export const apiClient: ApiClient = new ApiClient();
