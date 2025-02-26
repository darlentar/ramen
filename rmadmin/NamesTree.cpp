#include <cassert>
#include <QtGlobal>
#include <QAbstractItemModel>
#include <QDebug>
#include <QVariant>
#include "conf.h"
#include "misc.h"
#include "confValue.h"
#include "confWorkerRole.h"
#include "RamenType.h"
#include "NamesTree.h"

static bool const verbose = false;

NamesTree *NamesTree::globalNamesTree;
NamesTree *NamesTree::globalNamesTreeAnySites;

/*
 * What's used to store the names.
 */

class SubTree
{
  std::vector<SubTree *> children;

public:
  /* Cannot be const because SubTrees are constructed inplace, but
   * that's the idea: */
  QString name;

  SubTree *parent;

  bool isField;

  SubTree(QString const &name_, SubTree *parent_, bool isField_) :
    name(name_), parent(parent_), isField(isField_)
  {
    if (verbose)
      qDebug() << "NamesTree: Creating SubTree(name=" << name
               << ", parent=" << (parent ? parent->name : "none")
               << ")";
    children.reserve(10);
  }

  ~SubTree()
  {
    for (SubTree *c : children) delete c;
  }

  int count() const
  {
    return children.size();
  }

  SubTree *child(unsigned pos)
  {
    assert(pos < children.size());
    return children[pos];
  }

  int childNum(SubTree const *child) const
  {
    if (verbose)
      qDebug() << "childNum(" << child->name << ")" << "of" << name;

    for (int c = 0; c < (int)children.size(); c ++) {
      if (children[c]->name == child->name &&
          children[c] != child)
        qCritical() << "not unique child address for" << child->name << ";" << children[c] << "vs" << child;
      if (children[c] == child) return c;
    }
    assert(!"Not a child");
    return -1;
  }

  void dump(QString const &indent = "") const
  {
    for (SubTree *c : children) {
      qDebug() << indent << c->name << "(parent="
               << c->parent->name << ")";
      c->dump(indent + "  ");
    }
  }

  SubTree *insertAt(unsigned pos, QString const &name, bool isField)
  {
    SubTree *s = new SubTree(name, this, isField);
    children.insert(children.begin() + pos, s);
    return s;
  }
};

/*
 * The NamesTree itself:
 *
 * Also a model.
 * We then have a proxy than select only a subtree.
 */

NamesTree::NamesTree(bool withSites_, QObject *parent) :
  QAbstractItemModel(parent), withSites(withSites_)
{
  root = new SubTree(QString(), nullptr, false);

  connect(&kvs, &KVStore::valueCreated,
          this, &NamesTree::updateNames);
  connect(&kvs, &KVStore::valueChanged,
          this, &NamesTree::updateNames);
  connect(&kvs, &KVStore::valueDeleted,
          this, &NamesTree::deleteNames);
}

NamesTree::~NamesTree()
{
  delete root;
}

static bool isAWorker(std::string const &key)
{
  return startsWith(key, "sites/") && endsWith(key, "/worker");
}

// Empties [names]
SubTree *NamesTree::findOrCreate(
  SubTree *parent, QStringList &names, bool isField)
{
  if (names.count() == 0) return parent;

  QString const &name = names.takeFirst();

  /* Look for it in the (ordered) list of subtrees: */
  int i;
  for (i = 0; i < parent->count(); i ++) {
    SubTree *c = parent->child(i);
    if (name > c->name) continue;
    if (name == c->name) {
      if (verbose)
        qDebug() << "NamesTree:" << name << "already in the tree";
      return findOrCreate(c, names, isField);
    }
    break;
  }

  // Insert the new name at position i:
  QModelIndex parentIndex =
    parent == root ?
      QModelIndex() :
      createIndex(parent->parent->childNum(parent), 0, parent);
  beginInsertRows(parentIndex, i, i);
  SubTree *n = parent->insertAt(i, name, isField);
  endInsertRows();
  return findOrCreate(n, names, isField);
}

QModelIndex NamesTree::find(std::string const &path) const
{
  QStringList names(QString::fromStdString(path).
                    split('/', QString::SkipEmptyParts));

  QModelIndex idx;
  SubTree *parent = root;

  do {
    if (names.count() == 0) return idx;

    QString const &name = names.takeFirst();

    for (int i = 0; i < parent->count(); i ++) {
      SubTree *c = parent->child(i);
      if (name > c->name) continue;
      if (name < c->name) {
        if (verbose)
          qDebug() << "NamesTree: Cannot find" << QString::fromStdString(path);
        return QModelIndex();
      }
      parent = c;
      idx = index(i, 0, idx);
      break;
    }

  } while (true);
}

bool NamesTree::isField(QModelIndex const &index) const
{
  if (! index.isValid()) return false;

  SubTree *s = static_cast<SubTree *>(index.internalPointer());
  if (verbose)
    qDebug() << "NamesTree::isField:" << s->name
             << "is" << (s->isField ? "" : "not ") << "a field";

  return s->isField;
}

std::pair<std::string, std::string> NamesTree::pathOfIndex(
  QModelIndex const &index) const
{
  std::pair<std::string, std::string> ret { std::string(), std::string() };

  if (! index.isValid()) return ret;

  SubTree *s = static_cast<SubTree *>(index.internalPointer());
  while (s != root) {
    std::string *n = s->isField ? &ret.second : &ret.first;
    if (! n->empty()) n->insert(0, "/");
    n->insert(0, s->name.toStdString());
    s = s->parent;
  }

  return ret;
}

void NamesTree::updateNames(std::string const &key, KValue const &kv)
{
  if (! isAWorker(key)) return;

  std::shared_ptr<conf::Worker const> worker =
    std::dynamic_pointer_cast<conf::Worker const>(kv.val);
  if (! worker) {
    qCritical() << "Not a worker!?";
    return;
  }

  if (worker->role->isTopHalf) return;

  /* Get the site name, program name list and function name: */

  size_t const prefix_len = sizeof "sites/" - 1;
  size_t const workers_len = sizeof "/workers/" - 1;
  size_t const suffix_len = sizeof "/worker" - 1;
  size_t const min_names = sizeof "s/p/f" - 1;

  if (key.length() < prefix_len + workers_len + suffix_len + min_names) {
invalid_key:
    qCritical() << "Invalid worker key:" << QString::fromStdString(key);
    return;
  }

  size_t const end = key.length() - suffix_len;

  size_t i = key.find('/', prefix_len);
  if (i >= end) goto invalid_key;
  QString const site =
    QString::fromStdString(key.substr(prefix_len, i - prefix_len));

  // Skip "/workers/"
  i = key.find('/', i+1);
  if (i >= end) goto invalid_key;

  // Locate the function name at the end:
  size_t j = key.rfind('/', end - 1);
  if (j <= i) goto invalid_key;

  // Everything in between in the program name:
  std::string const programName(key.substr(i + 1, j - i - 1));
  std::string const srcPath = srcPathFromProgramName(programName);
  QString const programs = QString::fromStdString(programName);
  QStringList const program =
    programs.split('/', QString::SkipEmptyParts);
  QString const function =
    QString::fromStdString(key.substr(j + 1, end - j - 1));

  if (verbose)
    qDebug() << "NamesTree: found" << site << "/ "
              << programs << "/" << function;

  QStringList names(QStringList(site) << program << function);
  if (! withSites) names.removeFirst();

  SubTree *func = findOrCreate(root, names, false);

  /* Now get the field names */

  std::string infoKey =
    "sources/" + srcPath + "/info";

  std::shared_ptr<conf::SourceInfo const> sourceInfos;

  kvs.lock.lock_shared();
  auto it = kvs.map.find(infoKey);
  if (it == kvs.map.end()) {
    if (verbose)
      qDebug() << "NamesTree: No source info yet for" << QString::fromStdString(infoKey);
  } else {
    sourceInfos = std::dynamic_pointer_cast<conf::SourceInfo const>(it->second.val);
    if (! sourceInfos)
      qCritical() << "NamesTree: Not a SourceInfo!?";
  }
  kvs.lock.unlock_shared();

  if (! sourceInfos) return;
  if (sourceInfos->isError()) {
    if (verbose)
      qDebug() << "NamesTree:" << QString::fromStdString(infoKey) << "not compiled yet";
    return;
  }

  /* In the sourceInfos all functions of that program could be found, but for
   * simplicity let's add only the one we came for: */
  for (auto it : sourceInfos->infos) {
    if (it.name != function) continue;
    std::shared_ptr<RamenTypeStructure> s(it.outType->structure);
    /* FIXME: Each column should have subcolumns and all should be inserted
     * hierarchically. */
    for (int c = 0; c < s->numColumns(); c ++) {
      QStringList names(s->columnName(c));
      (void)findOrCreate(func, names, true);
    }
    break;
  }

  if (verbose) {
    qDebug() << "NamesTree: Current names-tree:";
    root->dump();
  }
}

void NamesTree::deleteNames(std::string const &key, KValue const &)
{
  if (! isAWorker(key)) return;

  // TODO: actually delete? Or keep the names around for a bit?
}

/*
 * The model for names
 */

QModelIndex NamesTree::index(int row, int column, QModelIndex const &parent) const
{
  SubTree *parentTree =
    parent.isValid() ?
      static_cast<SubTree *>(parent.internalPointer()) :
      root;

  if (row >= parentTree->count()) return QModelIndex();

  return createIndex(row, column, parentTree->child(row));
}

QModelIndex NamesTree::parent(QModelIndex const &index) const
{
  assert(index.isValid());

  SubTree *tree = static_cast<SubTree *>(index.internalPointer());
  if (tree->parent == root) return QModelIndex();
  return createIndex(tree->parent->childNum(tree), 0, tree->parent);
}

int NamesTree::rowCount(QModelIndex const &index) const
{
  if (! index.isValid()) return root->count();
  SubTree *tree = static_cast<SubTree *>(index.internalPointer());
  return tree->count();
 }

int NamesTree::columnCount(QModelIndex const &) const
{
  return 1;
}

QVariant NamesTree::data(QModelIndex const &index, int role) const
{
  assert(index.isValid());
  if (role != Qt::DisplayRole) return QVariant();
  SubTree *tree = static_cast<SubTree *>(index.internalPointer());
  return tree->name;
}

/*
 * If we are already in the subtree, then to ensure we do not leave it the only
 * function that require adapting is parent() (so we do not leave the subtree
 * up the root). index() also need to be adapted to enumeration starts from the
 * subtree.
 */

QModelIndex NamesSubtree::index(int row, int column, QModelIndex const &parent) const
{
  if (! parent.isValid())
    return NamesTree::index(row, column, newRoot);
  return NamesTree::index(row, column, parent);
}

QModelIndex NamesSubtree::parent(QModelIndex const &index) const
{
  if (index == newRoot) return QModelIndex();
  return NamesTree::parent(index);
}

/*
 * Just teach QCompleter how to to convert a string to/from a path:
 */

NamesCompleter::NamesCompleter(NamesTree *model_, QObject *parent) :
  QCompleter(model_, parent), model(model_)
{
  setCompletionRole(Qt::DisplayRole);
  setModelSorting(QCompleter::CaseSensitivelySortedModel);
}

QStringList NamesCompleter::splitPath(QString const &path) const
{
  /* Would be nice to SkipEmptyParts, but the last one must not be skipped, or
   * the completer would not jump to the next level of the tree. */
  return path.split('/');
}

QString NamesCompleter::pathFromIndex(QModelIndex const &index) const
{
  assert(index.isValid());

  SubTree *tree = static_cast<SubTree *>(index.internalPointer());

  QString ret(tree->name);

  while (tree->parent && tree->parent->parent) {
    tree = tree->parent;
    ret.prepend('/');
    ret.prepend(tree->name);
  }

  return ret;
}
