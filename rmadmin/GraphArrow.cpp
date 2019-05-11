#include <QPainter>
#include <QPainterPath>
#include "GraphArrow.h"
#include "OperationsItem.h"

/* Arrows only go in the margins, and the GraphArrow object is actually
 * given only the coordinates of the hlines and vlines to occupy, and a
 * channel number.
 * To be decided later if we have another Arrow object that's more
 * independent.
 *
 * The routing algorithm for arrows is, given the above simplification,
 * almost straightforward:
 * - When dest > src, first go straight until dest is reached and then
 *   go up/down and connect.
 * - When dest <= src, first turn vertical _in_the_other_direction_ than
 *   the target, then turn back, all the way to dest, then turn vertically
 *   again and connect. This avoid "S" shapes and make it look exactly
 *   like what it is:. a loop.
 *
 * Then channel attribution is a bit more complicated: for now we allocate
 * them at random, but ideally we'd like to engage z3 again to minimize
 * number of tiles where the same channel is occupied by more than one
 * arrow. */

GraphArrow::GraphArrow(GraphViewSettings const *settings_, int x0, int y0, int hmargin0, int x1, int y1, int hmargin1, QGraphicsItem *parent) :
  QGraphicsItem(parent),
  settings(settings_)
{
  // TODO: updateArrows should reallocate the channels:
  channel = std::rand() % settings->numArrowChannels;
  std::vector<Line> lines; // from src to dest

  int x = x0;
  int y = y0;

  if (x1 > x0) {
    x ++;
    if (y1 > y0) y++;
    for (; x < x1; x++)
      lines.push_back({ Right, x, y });
  } else {
    // We go round starting moving _away_ from dest so it looks more like
    // a loop:
    if (y1 <= y0) y++;
    for (; x >= x1; x--)
      lines.push_back({ Left, x, y });
    x ++;
  }
  if (y1 <= y)
    for (; y > y1; y--)
      lines.push_back({ Up, x, y });
  else
    for (; y < y1; y++)
      lines.push_back({ Down, x, y });

  int channelOffset =
    channel * settings->arrowChannelWidth -
    (settings->numArrowChannels * settings->arrowChannelWidth) / 2;

  QPointF startPos(
    (x0 + 1) * settings->gridWidth - hmargin0,
    y0 * settings->gridHeight + settings->gridHeight / 2 +
    channelOffset
  );

  QPointF targetPos(
    x1 * settings->gridWidth + hmargin1,
    y1 * settings->gridHeight + settings->gridHeight / 2 +
    channelOffset
  );

  path = new QPainterPath(startPos);
  path->lineTo(startPos + QPointF(hmargin0 + channelOffset, 0));

  // Go through these intermediary points:
  QPoint off(channelOffset, channelOffset);
  for (auto const &line : lines) {
    path->lineTo(line.start(settings) + off);
    path->lineTo(line.stop(settings) + off);
  }

  path->lineTo(targetPos + QPointF(channelOffset - hmargin1, 0));
  path->lineTo(targetPos);

  pathBBox = path->boundingRect();
}

GraphArrow::~GraphArrow()
{
  delete path;
}

QRectF GraphArrow::boundingRect() const
{
  return pathBBox;
}

void GraphArrow::paint(QPainter *painter, const QStyleOptionGraphicsItem *, QWidget *)
{
  QPen pen(Qt::SolidPattern, settings->arrowWidth, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin);
  painter->setPen(pen);
  painter->drawPath(*path);
}

QPointF GraphArrow::Line::start(GraphViewSettings const *settings) const
{
  switch (dir) {
    case Right:
    case Down:
      return settings->pointOfTile(x, y);
    case Left:
      return settings->pointOfTile(x + 1, y);
    case Up:
      return settings->pointOfTile(x, y + 1);
  }
}

QPointF GraphArrow::Line::stop(GraphViewSettings const *settings) const
{
  switch (dir) {
    case Left:
    case Up:
      return settings->pointOfTile(x, y);
    case Right:
      return settings->pointOfTile(x + 1, y);
    case Down:
      return settings->pointOfTile(x, y + 1);
  }
}
