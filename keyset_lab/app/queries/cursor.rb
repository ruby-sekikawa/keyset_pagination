# カーソルのシリアライズ（§6.5 最大の地雷）。
#
# iso8601(6) の "6"（マイクロ秒精度）が生命線。timestamp はマイクロ秒精度なので、
# to_s や iso8601（秒精度）で丸めると、同一秒内に複数行があるページ境界で取りこぼす。
# Base64 で包むのはカーソルを不透明にし、後からソートキーを変えても API 互換を保つため。
class Cursor
  def self.encode(record)
    payload = { t: record.created_at.iso8601(6), i: record.id }
    Base64.urlsafe_encode64(payload.to_json, padding: false)
  end

  def self.decode(str)
    return nil if str.blank?
    data = JSON.parse(Base64.urlsafe_decode64(str))
    { created_at: Time.iso8601(data["t"]), id: data["i"].to_i }
  rescue ArgumentError, JSON::ParserError
    nil # 壊れたカーソルは1ページ目扱いにする
  end
end
