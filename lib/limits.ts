/**
 * Giới hạn hiển thị & truy vấn dùng chung.
 * PostgREST cắt mặc định ở 1.000 dòng – KHÔNG truy vấn list mà không .limit()/.range().
 */
export const LIMITS = {
  tablePage: 50,        // số dòng render 1 lần trong bảng (Tổng quan, Tồn kho, Profit bridge)
  listPage: 30,         // số thẻ/danh sách 1 lần (Gợi ý, Ngoại lệ, Ticket, Nháp)
  feed: 100,            // nhật ký / lệnh
  detailItems: 50,      // tab trong chi tiết ASIN
  chartDays: 90,        // số ngày tối đa trên biểu đồ
  maxFetch: 1000,       // trần tuyệt đối cho 1 truy vấn client
} as const;

/** Lấy TOÀN BỘ dòng bằng cách phân trang qua trần 1.000 của PostgREST (dùng cho map ASIN khi import). */
export async function fetchAll<T>(build: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>, step = 1000): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += step) {
    const { data, error } = await build(from, from + step - 1);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if (!data || data.length < step) break;
  }
  return out;
}
