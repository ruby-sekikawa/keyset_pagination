class Api::OrdersController < ApplicationController
  def index
    result = OrderPageQuery.new(
      status: params[:status] || "paid",
      cursor: params[:cursor]
    ).call

    render json: {
      data: result.records.as_json(only: %i[id user_id status total_cents created_at]),
      next_cursor: result.next_cursor
    }
  end
end
